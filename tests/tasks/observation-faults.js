'use strict';

// Test-only preload: change the disposable target after a document blob is read.
const fs = require('node:fs');
const path = require('node:path');
const child = require('node:child_process');
const root = process.env.OBSERVATION_FIXTURE_ROOT;
const fault = process.env.OBSERVATION_FIXTURE_FAULT;
if (!root || !root.includes('/round-case-') || !root.endsWith('/retained workspace/prj')
    || !['worktree', 'index', 'head', 'lock', 'pending'].includes(fault)) {
    throw new Error('Invalid document-observation fixture fault');
}
const original = child.spawnSync;
let injected = false;
child.spawnSync = function (command, args, options) {
    const result = original.call(this, command, args, options);
    const cat = args.indexOf('cat-file');
    if (!injected && result.status === 0 && cat >= 0 && args[cat + 1] === 'blob'
        && args.includes(`--work-tree=${root}`)) {
        injected = true;
        if (fault === 'worktree') fs.writeFileSync(path.join(root, 'README.md'), 'Fixture changed while observing\n');
        else if (fault === 'index') fs.appendFileSync(path.join(root, '.git/index'), '\n');
        else if (fault === 'head') fs.writeFileSync(path.join(root, '.git/HEAD'), 'ref: refs/heads/changed-during-inspection\n');
        else if (fault === 'lock') fs.writeFileSync(path.join(root, '.git/index.lock'), 'Foreign lock appeared\n', { flag: 'wx' });
        else fs.writeFileSync(path.join(path.dirname(path.dirname(root)), 'state/pending.json'), '{}\n', { flag: 'wx' });
    }
    return result;
};
