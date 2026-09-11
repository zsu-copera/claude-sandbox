'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');

const script = [
    'set -euo pipefail',
    'source "$GUARD_SOURCE"',
    'podman() {',
    '  if [[ $1 == ps && $2 == --all ]]; then',
    '    printf "%s" "$GUARD_IDS"; return "$GUARD_PS_STATUS"',
    '  elif [[ $1 == container && $2 == inspect ]]; then',
    '    printf "%s" "$GUARD_METADATA"; return "$GUARD_INSPECT_STATUS"',
    '  fi',
    '  return 91',
    '}',
    'round_fixture_unmounted /fixtures/round-case',
].join('\n');

const cases = [
    ['no containers', '', [], 0, 0, true],
    ['unrelated container', 'id', [{ Mounts: [{ Type: 'bind', Source: '/another/workspace' }] }], 0, 0, true],
    ['wrapper operation child mount', 'id', [{ Mounts: [{ Type: 'bind', Source: '/fixtures/round-case/workspace/prj' }] }], 0, 0, false],
    ['stopped container exact mount', 'id', [{ State: { Running: false }, Mounts: [{ Type: 'bind', Source: '/fixtures/round-case' }] }], 0, 0, false],
    ['parent directory mount', 'id', [{ Mounts: [{ Type: 'bind', Source: '/fixtures' }] }], 0, 0, false],
    ['root mount', 'id', [{ Mounts: [{ Type: 'bind', Source: '/' }] }], 0, 0, false],
    ['missing mount metadata', 'id', [{}], 0, 0, false],
    ['container listing failure', '', [], 125, 0, false],
    ['container inspection failure', 'id', [], 0, 125, false],
];

for (const [name, ids, metadata, psStatus, inspectStatus, removable] of cases) {
    test(`fixture cleanup guard: ${name}`, () => {
        const result = spawnSync('/bin/bash', ['-c', script], {
            encoding: 'utf8',
            env: { PATH: '/usr/bin:/bin', GUARD_SOURCE: path.join(__dirname, 'mount-guard.sh'),
                GUARD_IDS: ids, GUARD_METADATA: JSON.stringify(metadata),
                GUARD_PS_STATUS: String(psStatus), GUARD_INSPECT_STATUS: String(inspectStatus) },
        });
        assert.equal(result.status, removable ? 0 : 1, result.stderr);
        if (!removable) assert.ok(result.stderr.trim(), 'Refusal must explain why the fixture is retained.');
    });
}
