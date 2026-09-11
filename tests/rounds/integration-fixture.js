'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createFixture, git, write, tree } = require('./fixtures');

const [action, base] = process.argv.slice(2);
assert.ok(base && path.isAbsolute(base) && base !== '/');

if (action === 'setup') {
    const f = createFixture(base);
    write(f.source, 'briefs/first brief.md', 'Uncommitted external edit, excluded from the packet.\n');
    write(base, 'before.json', JSON.stringify(tree(f.workspace)));
} else {
    const f = JSON.parse(fs.readFileSync(path.join(base, 'fixture.json'), 'utf8'));
    if (action === 'check-first' || action === 'check-second') {
        const round = action === 'check-first' ? 'R1' : 'R2';
        const snapshot = path.join(f.target, `sandbox-rounds/TASK_42/${round}`);
        assert.match(fs.readFileSync(path.join(snapshot, 'files/briefs/first brief.md'), 'utf8'), /First committed review/);
        assert.equal(fs.readFileSync(path.join(snapshot, 'files/briefs/second.txt'), 'utf8'), 'Second supporting text.\r\n');
        const before = JSON.parse(fs.readFileSync(path.join(base, 'before.json'), 'utf8'));
        const after = tree(f.workspace);
        for (const [name, value] of Object.entries(before)) {
            if (name !== 'prj/.git' && !name.startsWith('prj/.git/')) assert.deepEqual(after[name], value, name);
        }
        assert.equal(git(f.target, 'branch', '--show-current'), 'sandbox-fixture');
        assert.equal(git(f.target, 'status', '--porcelain'), '');
        if (round === 'R1') {
            assert.equal(git(f.target, 'rev-parse', 'HEAD^'), f.baseHead);
            write(base, 'first-round-tree.json', JSON.stringify(tree(path.join(f.target, 'sandbox-rounds/TASK_42/R1'))));
            write(base, 'first-head.txt', git(f.target, 'rev-parse', 'HEAD'));
        } else {
            assert.equal(git(f.target, 'rev-parse', 'HEAD^'), fs.readFileSync(path.join(base, 'first-head.txt'), 'utf8'));
            assert.deepEqual(tree(path.join(f.target, 'sandbox-rounds/TASK_42/R1')),
                JSON.parse(fs.readFileSync(path.join(base, 'first-round-tree.json'), 'utf8')));
        }
    } else if (action === 'preview-before') {
        write(base, 'preview-tree.json', JSON.stringify(tree(f.workspace)));
    } else if (action === 'preview-after') {
        assert.deepEqual(tree(f.workspace), JSON.parse(fs.readFileSync(path.join(base, 'preview-tree.json'), 'utf8')));
    } else if (action === 'dirty') {
        write(f.target, 'not-yet-reviewed.txt', 'Do not remove operator work\n');
    } else if (action === 'clear-dirty') {
        fs.unlinkSync(path.join(f.target, 'not-yet-reviewed.txt'));
    } else if (action === 'invalid-packet') {
        write(f.packets, 'invalid.json', '{"version":');
    } else {
        throw new Error('Unknown fixture action');
    }
}
