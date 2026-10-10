#!/usr/bin/env python3
"""Project-owned UI evidence gate. Requires Git and Python's standard library.

Copy only when the consuming project lacks equivalent enforcement. Configuration,
standards and review evidence belong to that project. This validates records and file
integrity; it cannot establish that a human approved an exception or inspected a UI.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import struct
import subprocess
import sys
import zlib

MAX_JSON = 1_000_000
MAX_IMAGE = 20_000_000

class ReviewError(ValueError):
    pass

def require(condition, message):
    if not condition:
        raise ReviewError(message)

def text(value):
    return isinstance(value, str) and bool(value.strip())

def git(root, *args):
    result = subprocess.run(['git', '-C', str(root), *args], capture_output=True)
    require(result.returncode == 0, 'Git failed: ' + result.stderr.decode(errors='replace').strip())
    return result.stdout

def relative(name):
    require(text(name) and '\\' not in name, 'Expected a repository-relative POSIX path')
    p = PurePosixPath(name)
    require(not p.is_absolute() and '..' not in p.parts and p.parts and p.as_posix() == name.rstrip('/'), 'Unsafe path: ' + name)
    require(p.parts[0] != '.git', 'Git internals are not review inputs')
    return p.as_posix()

def safe_file(root, name):
    p = root / relative(name)
    for part in (p, *p.parents):
        if part == root:
            break
        require(not part.is_symlink(), 'Symlink is not a review input: ' + name)
    require(p.is_file(), 'Missing regular file: ' + name)
    return p

def load_json(root, name):
    p = safe_file(root, name)
    require(p.stat().st_size <= MAX_JSON, 'Oversized JSON: ' + name)
    def pairs(items):
        obj = {}
        for key, value in items:
            require(key not in obj, 'Duplicate JSON key: ' + key)
            obj[key] = value
        return obj
    return json.loads(p.read_text(), object_pairs_hook=pairs)

def nonempty_list(value, label):
    require(isinstance(value, list) and value and all(text(v) for v in value) and len(set(value)) == len(value), 'Invalid ' + label)
    return value

def config(value):
    require(isinstance(value, dict) and value.get('version') == 1, 'Unsupported gate configuration')
    for key in ('ui_paths', 'canonical_files', 'guardrail_files', 'viewports', 'checks', 'rule_ids'):
        nonempty_list(value.get(key), key)
    for name in value['ui_paths'] + value['canonical_files'] + value['guardrail_files']:
        relative(name)
    for key in ('review_dir', 'evidence_dir'):
        relative(value.get(key))
        require(value[key].endswith('/'), key + ' must be a directory ending in /')
    require(value['review_dir'] != value['evidence_dir'], 'Reviews and screenshots need distinct directories')
    return value

def digest(root, name):
    p = root / relative(name)
    for part in (p, *p.parents):
        if part == root:
            break
        require(not part.is_symlink(), 'Symlink is not a review input: ' + name)
    if not p.exists():
        return None
    return hashlib.sha256(safe_file(root, name).read_bytes()).hexdigest()

def changed_paths(root, base):
    parts = git(root, 'diff', '--name-status', '-z', '--find-renames', base, '--').decode().split('\0')
    paths = set()
    index = 0
    while index < len(parts) and parts[index]:
        status = parts[index]
        count = 2 if status.startswith(('R', 'C')) else 1
        paths.update(parts[index + 1:index + 1 + count])
        index += count + 1
    paths.update(p for p in git(root, 'ls-files', '--others', '--exclude-standard', '-z').decode().split('\0') if p)
    return paths

def matches(name, scopes):
    return any(name.startswith(scope) if scope.endswith('/') else name == scope for scope in scopes)

def image(root, name, directory):
    require(name.startswith(directory), 'Screenshot is outside the configured evidence directory')
    p = safe_file(root, name)
    require(32 <= p.stat().st_size <= MAX_IMAGE, 'Invalid screenshot size: ' + name)
    data = p.read_bytes()
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        offset = 8
        kinds = []
        while offset + 12 <= len(data):
            size = struct.unpack('>I', data[offset:offset + 4])[0]
            end = offset + size + 12
            require(end <= len(data), 'Truncated PNG: ' + name)
            kind = data[offset + 4:offset + 8]
            payload = data[offset + 8:offset + 8 + size]
            crc = struct.unpack('>I', data[offset + 8 + size:end])[0]
            require(zlib.crc32(kind + payload) == crc, 'Invalid PNG checksum: ' + name)
            if not kinds:
                require(kind == b'IHDR' and size == 13, 'Missing PNG header: ' + name)
                width, height = struct.unpack('>II', payload[:8])
                require(width > 0 and height > 0, 'Invalid PNG dimensions: ' + name)
            kinds.append(kind)
            offset = end
            if kind == b'IEND':
                break
        require(offset == len(data) and b'IDAT' in kinds and kinds[-1] == b'IEND', 'Incomplete PNG: ' + name)
    elif data.startswith(b'\xff\xd8\xff'):
        require(data.endswith(b'\xff\xd9'), 'Incomplete JPEG: ' + name)
    else:
        require(data[:4] == b'RIFF' and data[8:12] == b'WEBP' and struct.unpack('<I', data[4:8])[0] + 8 == len(data), 'Unsupported screenshot: ' + name)
        require(data[12:16] in (b'VP8 ', b'VP8L', b'VP8X'), 'Invalid WebP header: ' + name)

def review(root, value, cfg, base, expected, standards, policy_changes, ui_changed):
    require(isinstance(value, dict) and value.get('version') == 1, 'Unsupported review record')
    require(value.get('base') == base, 'Review was written against a different base')
    require(value.get('paths') == expected, 'Review does not cover the exact current changed files and hashes')
    require(value.get('standards') == standards, 'Review did not load the current canonical standards')
    require(text(value.get('reviewer')), 'Missing reviewer')
    rules = nonempty_list(value.get('rules'), 'applied rules')
    require(set(rules) <= set(cfg['rule_ids']), 'Unknown project rule identifier')
    scenarios = value.get('scenarios')
    require(isinstance(scenarios, list) and scenarios and all(isinstance(s, dict) and text(s.get('scenario')) and text(s.get('observed')) for s in scenarios), 'Missing observed scenarios')
    checks = value.get('checks')
    require(isinstance(checks, dict), 'Missing check results')
    for name in cfg['checks']:
        entry = checks.get(name, {})
        require(isinstance(entry, dict) and entry.get('result') == 'pass' and text(entry.get('command')) and text(entry.get('observed')), 'Required check did not pass: ' + name)
    screenshots = value.get('screenshots')
    require(isinstance(screenshots, dict), 'Missing inspected screenshots')
    for viewport in cfg['viewports'] if ui_changed else []:
        entry = screenshots.get(viewport, {})
        require(isinstance(entry, dict) and text(entry.get('path')) and text(entry.get('inspected')), 'Missing inspected viewport: ' + viewport)
        image(root, entry['path'], cfg['evidence_dir'])
        require(entry.get('sha256') == digest(root, entry['path']), 'Screenshot changed after inspection: ' + viewport)
    require(isinstance(value.get('limitations'), list) and all(text(v) for v in value['limitations']), 'List unproven checks explicitly')
    exceptions = value.get('exceptions')
    require(isinstance(exceptions, list), 'Missing exception declarations')
    approved = set()
    for entry in exceptions:
        require(isinstance(entry, dict) and text(entry.get('reason')) and text(entry.get('approval')), 'Exception needs scope, reason and approval reference')
        approved.update(nonempty_list(entry.get('paths'), 'exception paths'))
    require(policy_changes <= approved, 'Changed canonical policy or gate configuration needs explicit human approval recorded')

def check(args):
    root = Path(git(Path.cwd(), 'rev-parse', '--show-toplevel').decode().strip()).resolve()
    config_name = relative(args.config)
    require(not args.base.startswith('-'), 'Invalid base ref')
    base = git(root, 'rev-parse', '--verify', args.base + '^{commit}').decode().strip()
    git(root, 'merge-base', '--is-ancestor', base, 'HEAD')
    cfg = config(load_json(root, config_name))
    tracked_config = subprocess.run(['git', '-C', str(root), 'show', base + ':' + config_name], capture_output=True)
    previous = config(json.loads(tracked_config.stdout)) if tracked_config.returncode == 0 else None
    changed = changed_paths(root, base)
    scopes = cfg['ui_paths'] + (previous['ui_paths'] if previous else [])
    canonical = set(cfg['canonical_files']) | (set(previous['canonical_files']) if previous else set())
    guardrails = set(cfg['guardrail_files']) | (set(previous['guardrail_files']) if previous else set())
    protected = canonical | guardrails | {config_name}
    for name in cfg['canonical_files'] + cfg['guardrail_files']:
        safe_file(root, name)
    affected = {p for p in changed if matches(p, scopes) or p in protected}
    if not affected:
        print('UI review gate: no affected UI or policy files')
        return
    expected = {p: digest(root, p) for p in sorted(affected)}
    standards = {p: digest(root, p) for p in sorted(canonical)}
    # Initial setup adopts existing policy; later edits cannot silently remove old scope.
    base_files = set(p for p in git(root, 'ls-tree', '-r', '--name-only', '-z', base).decode().split('\0') if p)
    policy_changes = (affected & protected) if previous else (affected & protected & base_files)
    if previous is None and not policy_changes and not any(matches(p, scopes) for p in affected):
        print('UI review gate: initial policy setup only; no UI verification claimed')
        return
    records = sorted(p for p in changed if p.startswith(cfg['review_dir']) and p.endswith('.json') and (root / p).exists())
    require(records, 'UI changes need a new or updated review record in ' + cfg['review_dir'])
    errors = []
    for name in records:
        try:
            review(root, load_json(root, name), cfg, base, expected, standards, policy_changes, any(matches(p, scopes) for p in affected))
            print('UI review gate: PASS (' + name + ')')
            return
        except (ReviewError, ValueError, OSError, TypeError) as error:
            errors.append(name + ': ' + str(error))
    raise ReviewError('\n'.join(errors))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True, help='Project-owned JSON configuration, relative to Git root')
    parser.add_argument('--base', required=True, help='Trusted review base from project workflow, never a convenient recent commit')
    args = parser.parse_args()
    try:
        check(args)
    except (ReviewError, ValueError, OSError, TypeError, KeyError, IndexError) as error:
        print('UI review gate: FAIL\n' + str(error), file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main())
