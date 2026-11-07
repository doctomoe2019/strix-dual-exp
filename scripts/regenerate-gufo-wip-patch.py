#!/usr/bin/env python3
"""Regenerate the public gufo WIP patch from the local branch.

Drops the whole-file exclusions the published patch has always omitted
(private campaign notes and goal journals), then privacy-scans the result.
Run after every gufo commit, then commit the patch here and push.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path('/root/gufo')
BASE = '2833856874ee75bde8252b6a7f6b9ae0b00a3012'
OUTPUT = Path('/root/strix-dual-exp/gufo/0001-feat-tp2-tbstream-wip.patch')
EXCLUDED = {
    '.opencode/goal/2026-10-10-glm-prefill-250-vllm/goal.json',
    '.opencode/goal/2026-10-10-glm-prefill-250-vllm/plan.md',
    '.opencode/goal/2026-10-10-glm-prefill-250-vllm/status.md',
    '.opencode/goal/2026-10-10-glm-prefill-250/goal.json',
    '.opencode/goal/2026-10-10-glm-prefill-250/plan.md',
    'notes/pair-250.md',
    'notes/pair-ws-250.md',
    'notes/ple-native/01-source.md',
    'notes/ple-native/02-candidate-pack.md',
    'notes/ple-native/03-quality-screen.md',
    'notes/ple-native/04-perf-ab.md',
    'notes/ple-native/05-final.md',
    'notes/ple-native/scripts/ple-native-adopt.sh',
    'notes/ple-native/scripts/ple-native-loadtest.sh',
    'notes/ple-native/scripts/ple-native-pair.sh',
    'notes/ple-native/scripts/ple-native-probe.sh',
    'notes/ple-native/scripts/ple_native_perf.py',
    'notes/ple-native/scripts/ple_native_window1.sh',
    'notes/ple-native/scripts/ple_native_window2.sh',
    'notes/ple-native/scripts/ple_native_window6.sh',
    'notes/serving-ws-250.md',
}
SCANS = {
    'deployment hosts': r'\bstrix[12]\b',
    'deployment link addresses': r'\b10\.55\.\d+\.\d+\b',
    'private keys': r'-----BEGIN (?:OPENSSH|RSA|EC|DSA|PRIVATE).*PRIVATE KEY-----',
    'API credentials': r'\b(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat__[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{24,})',
    'MAC addresses': r'\b(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}\b',
}

revision = sys.argv[1] if len(sys.argv) > 1 else 'HEAD'
raw = subprocess.check_output(['git', 'diff', f'{BASE}..{revision}'],
                              cwd=REPO).decode()
# Sections already public in the previously published patch revision.
old_patch = subprocess.check_output(
    ['git', 'show', 'HEAD:gufo/0001-feat-tp2-tbstream-wip.patch'],
    cwd='/root/strix-dual-exp').decode()
previously = set(re.findall(r'^diff --git a/(.*?) b/', old_patch, re.M))
parts = re.split(r'(?=^diff --git )', raw, flags=re.M)
published, omitted = [], []
for part in parts:
    if not part:
        continue
    path = re.match(r'diff --git a/(.*?) b/', part).group(1)
    (omitted if path in EXCLUDED else published).append(part)
text = ''.join(published)
unknown = {re.match(r'diff --git a/(.*?) b/', part).group(1)
           for part in published
           if (lambda p: p.startswith('notes/') or p.startswith('.opencode/'))(
               re.match(r'diff --git a/(.*?) b/', part).group(1))
           and re.match(r'diff --git a/(.*?) b/', part).group(1)
           not in previously}
assert not unknown, 'new private-tree sections need a decision: ' + ', '.join(sorted(unknown))
for label, pattern in SCANS.items():
    assert not re.search(pattern, text), 'privacy scan failed: ' + label
OUTPUT.write_text(text)
print(json.dumps({'output': str(OUTPUT), 'sections': len(published),
                  'excluded': len(omitted), 'bytes': len(text.encode()),
                  'privacy_scan': 'pass'}))
