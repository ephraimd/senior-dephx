"""Exercise the shipped gate against real repositories, not a copied implementation."""
import hashlib
import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zlib
import struct

ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / 'skills/ui-craft/assets/check-ui-review.py'

def image_bytes():
    def chunk(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(b'\0\0\0\0')) + chunk(b'IEND', b'')

class RepositoryGate(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dephx-gate-')
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.test')
        self.config = {'version': 1, 'ui_paths': ['app/', 'public/'],
                       'canonical_files': ['docs/ux.md', 'docs/copy.json'],
                       'review_dir': 'reviews/ui/', 'evidence_dir': 'reviews/images/',
                       'viewports': ['phone', 'short-phone', 'tablet', 'desktop'],
                       'checks': ['unit', 'browser'], 'rule_ids': ['UX-1'],
                       'guardrail_files': ['tools/check-ui-review.py', '.github/workflows/checks.yml', 'AGENTS.md']}
        self.write('tools/check-ui-review.py', '# Existing gate implementation\n')
        self.write('.github/workflows/checks.yml', 'name: Existing checks\n')
        self.write('AGENTS.md', '# Existing instructions\n')
        self.write('docs/ux.md', 'UX-1: Stable task controls. Contract 7.\n')
        self.write('docs/copy.json', '{"heading":"Your tickets, ready for a reply."}\n')
        self.write('app/tickets.html', '<h1>Tickets</h1>\n')
        self.write('public/theme.css', 'body { color: black; }\n')
        self.write('docs/ui-review.json', json.dumps(self.config))
        self.git('add', 'docs/ux.md', 'docs/copy.json', 'docs/ui-review.json', 'app/tickets.html', 'public/theme.css', 'tools/check-ui-review.py', '.github/workflows/checks.yml', 'AGENTS.md')
        self.git('commit', '-qm', 'Initial fixture')
        self.base = self.git('rev-parse', 'HEAD').strip()

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.root), *args], text=True, capture_output=True, check=True).stdout

    def write(self, name, value):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(value, bytes): p.write_bytes(value)
        else: p.write_text(value)

    def digest(self, name):
        return hashlib.sha256((self.root / name).read_bytes()).hexdigest() if (self.root / name).exists() else None

    def record(self, paths=None):
        paths = paths or ['app/tickets.html']
        for viewport in self.config['viewports']:
            self.write(f'reviews/images/{viewport}.png', image_bytes())
        value = {'version': 1, 'base': self.base, 'reviewer': 'Independent fixture reviewer',
                 'paths': {p: self.digest(p) if (self.root / p).exists() else None for p in paths},
                 'standards': {p: self.digest(p) for p in self.config['canonical_files']},
                 'rules': ['UX-1'], 'scenarios': [{'scenario': 'Long ticket queue', 'observed': 'Controls remain reachable'}],
                 'checks': {c: {'command': f'make {c}', 'result': 'pass', 'observed': 'Fixture command passed'} for c in self.config['checks']},
                 'screenshots': {v: {'path': f'reviews/images/{v}.png', 'inspected': 'Fixture screenshot inspected', 'sha256': self.digest(f'reviews/images/{v}.png')} for v in self.config['viewports']},
                 'limitations': ['Synthetic image verifies file validation only.'], 'exceptions': []}
        self.save_record(value)
        return value

    def save_record(self, value): self.write('reviews/ui/change.json', json.dumps(value))
    def change(self): self.write('app/tickets.html', '<h1>Tickets</h1><button>Filter</button>\n')
    def gate(self, expected, base=None):
        self.assertTrue(GATE.is_file(), 'Portable review gate asset is missing')
        result = subprocess.run(['python3', str(GATE), '--config', 'docs/ui-review.json', '--base', base or self.base], cwd=self.root, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, expected, result.stdout + result.stderr)
        return result

    def test_startup_hook_injects_setup_policy_without_repository_writes(self):
        def snapshot():
            return {str(p.relative_to(self.root)):p.read_bytes() for p in self.root.rglob('*') if p.is_file() and '.git' not in p.relative_to(self.root).parts}
        before=snapshot()
        result=subprocess.run(['bash',str(ROOT/'hooks/session-start.sh')],cwd=self.root,env={**os.environ,'CLAUDE_PLUGIN_ROOT':str(ROOT)},text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('assess repository enforcement',result.stdout)
        self.assertEqual(snapshot(),before)
    def test_non_ui_change_needs_no_review(self): self.write('server/readme.md', 'Backend notes'); self.gate(True)
    def test_missing_review_blocks_ui(self): self.change(); self.gate(False)
    def test_complete_project_specific_record_passes(self): self.change(); self.record(); self.gate(True)
    def test_deletion_requires_coverage(self): (self.root / 'app/tickets.html').unlink(); self.gate(False); self.record(); self.gate(True)
    def test_rename_tracks_both_paths(self):
        self.git('mv', 'app/tickets.html', 'app/queue.html'); self.record(['app/queue.html']); self.gate(False)
        self.record(['app/tickets.html', 'app/queue.html']); self.gate(True)
    def test_untracked_ui_requires_review(self):
        self.write('app/new.html', '<p>New</p>'); self.gate(False); self.record(['app/new.html']); self.gate(True)
    def test_stale_code_hash_fails(self): self.change(); self.record(); self.write('app/tickets.html', '<p>Unreviewed</p>'); self.gate(False)
    def test_stale_base_fails(self): self.change(); value=self.record(); value['base']='0'*40; self.save_record(value); self.gate(False)
    def test_unchanged_old_record_is_not_current_review(self):
        self.change(); self.record(); self.git('add', 'app/tickets.html', 'reviews'); self.git('commit', '-qm', 'Reviewed feature')
        self.base=self.git('rev-parse','HEAD').strip(); self.write('app/tickets.html', '<p>Next unreviewed change</p>'); self.gate(False)
    def test_standards_hash_mismatch_fails(self):
        self.change(); value=self.record(); value['standards']['docs/ux.md']='0'*64; self.save_record(value); self.gate(False)
    def test_policy_change_requires_approved_exception(self):
        self.write('docs/ux.md', 'UX-1: Changed contract 8\n'); value=self.record(['docs/ux.md']); self.gate(False)
        value['exceptions']=[{'paths':['docs/ux.md'], 'reason':'Approved revised contract', 'approval':'Issue 42, explicit owner approval'}]; self.save_record(value); self.gate(True)
    def test_narrowed_scope_still_protects_old_ui(self):
        self.config['ui_paths']=['public/']; self.write('docs/ui-review.json', json.dumps(self.config)); self.change(); self.gate(False)
    def test_removed_canonical_file_still_requires_approval(self):
        self.config['canonical_files']=['docs/copy.json']; self.write('docs/ui-review.json', json.dumps(self.config)); (self.root/'docs/ux.md').unlink(); self.gate(False)
    def test_missing_required_viewport_fails(self):
        self.change(); value=self.record(); del value['screenshots']['short-phone']; self.save_record(value); self.gate(False)
    def test_failed_check_blocks(self):
        self.change(); value=self.record(); value['checks']['browser']['result']='fail'; self.save_record(value); self.gate(False)
    def test_external_image_is_rejected(self):
        self.change(); value=self.record(); value['screenshots']['phone']['path']='../outside.png'; self.save_record(value); self.gate(False)
    def test_image_symlink_is_rejected(self):
        self.change(); self.record(); p=self.root/'reviews/images/phone.png'; p.unlink(); p.symlink_to(self.root/'reviews/images/desktop.png'); self.gate(False)
    def test_corrupt_image_rejected(self): self.change(); self.record(); self.write('reviews/images/phone.png', b'not a screenshot'); self.gate(False)
    def test_unknown_base_fails(self): self.gate(False, 'missing-base')
    def test_nonancestor_base_fails(self):
        self.git('checkout', '--orphan', 'unrelated'); self.write('other.md','New unrelated history'); self.git('add','other.md'); self.git('commit','-qm','Orphan'); self.gate(False)
    def test_bootstrap_existing_enforcement_cannot_be_overwritten(self):
        self.git('rm','docs/ui-review.json'); self.git('commit','-qm','Repo without config'); self.base=self.git('rev-parse','HEAD').strip()
        self.write('docs/ui-review.json', json.dumps(self.config)); self.write('AGENTS.md','# Weakened'); self.write('.github/workflows/checks.yml','name: Bypass'); self.gate(False)
    def test_dangling_ui_symlink_is_not_a_deletion(self):
        p=self.root/'app/tickets.html'; p.unlink(); p.symlink_to('missing.html'); self.record(); self.gate(False)
    def test_replaced_image_invalidates_inspection(self):
        self.change(); self.record(); self.write('reviews/images/phone.png', image_bytes()+b'extra'); self.gate(False)
    def test_valid_replaced_image_invalidates_inspection(self):
        self.change(); self.record()
        other=image_bytes().replace(b'IHDR',b'IHDR',1)
        # A different valid PNG payload, retaining a valid CRC and container.
        offset=other.index(b'IDAT'); size=int.from_bytes(other[offset-4:offset],'big'); end=offset+4+size
        payload=zlib.compress(b'\0\xff\0\0'); replacement=len(payload).to_bytes(4,'big')+b'IDAT'+payload+zlib.crc32(b'IDAT'+payload).to_bytes(4,'big')
        other=other[:offset-4]+replacement+other[end+4:]
        self.write('reviews/images/phone.png',other); self.gate(False)
    def test_policy_only_changes_need_no_fake_screenshots(self):
        self.write('docs/ux.md','UX-1: Clarified policy'); value=self.record(['docs/ux.md']); value['screenshots']={}
        value['exceptions']=[{'paths':['docs/ux.md'],'reason':'Owner-authorized clarification','approval':'Fixture task explicitly authorizes this policy edit'}]; self.save_record(value); self.gate(True)
    def test_changed_gate_implementation_requires_review(self): self.write('tools/check-ui-review.py', '# Weakened gate'); self.gate(False)
    def test_changed_ci_requires_review(self): self.write('.github/workflows/checks.yml', 'name: Bypass'); self.gate(False)
    def test_missing_current_standard_cannot_be_claimed_loaded(self):
        self.git('rm','docs/ux.md'); self.git('commit','-qm','Broken missing standard'); self.base=self.git('rev-parse','HEAD').strip()
        self.change(); self.record(); self.gate(False)
    def test_changed_root_instructions_require_review(self): self.write('AGENTS.md', '# Looser rules'); self.gate(False)
    def test_config_traversal_rejected(self):
        self.config['ui_paths']=['../other/']; self.write('docs/ui-review.json',json.dumps(self.config)); self.gate(False)
    def test_deleted_gate_config_fails(self): (self.root/'docs/ui-review.json').unlink(); self.gate(False)
    def test_bootstrap_without_ui_does_not_invent_visual_evidence(self):
        self.git('rm','docs/ui-review.json'); self.git('commit','-qm','Repo without gate'); self.base=self.git('rev-parse','HEAD').strip()
        self.write('docs/ui-review.json', json.dumps(self.config)); self.gate(True)
    def test_bootstrap_cannot_rewrite_existing_standards_without_review(self):
        self.git('rm','docs/ui-review.json'); self.git('commit','-qm','Repo without gate'); self.base=self.git('rev-parse','HEAD').strip()
        self.write('docs/ui-review.json', json.dumps(self.config)); self.write('docs/ux.md','Looser policy'); self.gate(False)
    def test_initial_contract_can_be_added_without_fake_visual_evidence(self):
        self.git('rm','docs/ui-review.json','docs/ux.md','docs/copy.json'); self.git('commit','-qm','Repo without standards'); self.base=self.git('rev-parse','HEAD').strip()
        self.write('docs/ui-review.json', json.dumps(self.config)); self.write('docs/ux.md','UX-1: Stable controls'); self.write('docs/copy.json','{}'); self.gate(True)
    def test_new_bootstrap_config_checks_existing_changed_ui(self):
        self.git('rm','docs/ui-review.json'); self.git('commit','-qm','Old repo without gate'); self.base=self.git('rev-parse','HEAD').strip()
        self.write('docs/ui-review.json', json.dumps(self.config)); self.change(); self.gate(False); self.record(['app/tickets.html','docs/ui-review.json']); self.gate(True)

if __name__ == '__main__': unittest.main()
