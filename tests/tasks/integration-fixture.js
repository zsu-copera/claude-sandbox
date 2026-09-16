'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { createFixture, repository, git, write, tree, sha256 } = require('../rounds/fixtures');

process.umask(0o077);
const [mode, hostRoot] = process.argv.slice(2);
const root = '/fixtures';
const read = name => JSON.parse(fs.readFileSync(path.join(root, name)));
const mapped = value => path.join(root, path.relative(hostRoot, value));
function commit(repo, name, content) {
    write(repo, name, content);
    git(repo, 'add', name);
    git(repo, 'commit', '--quiet', '-m', 'Task integration fixture change');
}
if (mode === 'setup') {
    const f = createFixture(root);
    const docsSource = path.join(root, 'external documentation');
    repository(docsSource);
    commit(docsSource, 'review.md', '# First documentation brief\n');
    const config = { version: 1, task: 'TASK-1', workspace: `${hostRoot}/retained workspace`,
        image: process.argv[4], profiles: ['agencyWWW'], repositories: {
            prj: { source: `${hostRoot}/external source`, ref: 'refs/heads/sandbox-fixture',
                auditBase: f.baseHead, briefs: ['briefs/first brief.md'] },
            Documentation: { source: `${hostRoot}/external documentation`, ref: 'refs/heads/sandbox-fixture',
                auditBase: git(f.documentation, 'rev-parse', 'HEAD'), briefs: ['review.md'] },
        } };
    write(root, 'config.json', JSON.stringify(config));
    write(root, 'before.json', JSON.stringify({ workspace: tree(f.workspace), source: tree(f.source),
        documentation: tree(docsSource) }));
} else {
    const f = read('fixture.json');
    const docsSource = path.join(root, 'external documentation');
    if (mode === 'observation-dirty') {
        write(root, 'observation-original.txt', fs.readFileSync(path.join(f.target, 'README.md')));
        write(f.target, 'README.md', 'Pending canonical document edit\n');
    } else if (mode === 'observation-restore') {
        write(f.target, 'README.md', fs.readFileSync(path.join(root, 'observation-original.txt')));
    } else if (mode === 'check-observations') {
        const before = read('before.json');
        assert.deepEqual(tree(f.workspace), before.workspace);
        assert.deepEqual(tree(f.source), before.source);
        assert.deepEqual(tree(docsSource), before.documentation);
        const { documents, ...legacy } = read('observation-clean.json');
        assert.deepEqual(legacy, read('observation-legacy.json'));
        assert.deepEqual(documents.map(item => item.path), ['README.md', 'missing.md']);
        assert.equal(documents[0].observation.sha256, sha256(Buffer.from('Canonical README remains unchanged.\n')));
        assert.equal(documents[1].observation.state, 'missing');
        const source = read('observation-source.json');
        assert.equal(source.head, f.sourceHead);
        assert.equal(source.documents[0].observation.sha256, sha256(Buffer.from('# First committed review\n\nUse the retained caches.\n')));
        assert.equal(source.documents[1].observation.state, 'missing');
        const dirty = read('observation-dirty.json');
        assert.equal(dirty.status, 'dirty');
        assert.deepEqual(dirty.documents, [{ path: 'README.md', observation: { state: 'unobserved', reason: 'dirty' } }]);
        const running = read('observation-running.json');
        assert.equal(running.status, 'running');
        assert.equal(running.observedWorktree, false);
        assert.ok(!Object.hasOwn(running, 'head'));
        assert.deepEqual(running.documents, ['README.md', 'missing.md'].map(name => ({
            path: name, observation: { state: 'unobserved', reason: 'running' },
        })));
    } else if (mode === 'check-plan') {
        const before = read('before.json');
        assert.deepEqual(tree(f.workspace), before.workspace, 'Register and planning must not modify workspace');
        assert.deepEqual(tree(f.source), before.source);
        assert.deepEqual(tree(docsSource), before.documentation);
        const plan = read('plan.json');
        assert.equal(plan.status, 'approval-required');
        assert.equal(plan.round, 'R1');
        assert.equal(plan.planId, read('repeat.json').planId);
        assert.equal(plan.prepares, false);
        assert.equal(plan.launchesAgent, false);
    } else if (mode === 'check-first') {
        const result = read('applied.json');
        assert.equal(result.status, 'applied');
        for (const repo of [f.target, f.documentation]) {
            assert.equal(git(repo, 'rev-list', '--count', 'HEAD'), '2');
            assert.equal(git(repo, 'branch', '--show-current'), 'sandbox-fixture');
            assert.equal(git(repo, 'remote'), '');
            assert.equal(fs.readFileSync(path.join(repo, '.cache/sentinel'), 'utf8'), 'Retained .cache\n');
        }
        write(root, 'first-head.json', JSON.stringify({ prj: git(f.target, 'rev-parse', 'HEAD') }));
        assert.equal(fs.readFileSync(path.join(f.workspace, '.m2/repository/sentinel'), 'utf8'), 'Retained Maven cache\n');
    } else if (mode === 'unrelated') {
        commit(f.source, 'unrelated.txt', 'This source commit does not change the selected brief.\n');
    } else if (mode === 'docs-update') {
        commit(docsSource, 'review.md', '# Second documentation brief\n');
    } else if (mode === 'check-second') {
        assert.equal(read('second-plan.json').repositories.prj.action, 'preserve');
        assert.equal(git(f.target, 'rev-parse', 'HEAD'), read('first-head.json').prj);
        assert.equal(git(f.documentation, 'rev-list', '--count', 'HEAD'), '3');
    } else if (mode === 'result') {
        commit(f.target, 'src/original.txt', 'Committed sandbox implementation\n');
        write(root, 'collect-before.json', JSON.stringify(tree(f.workspace)));
    } else if (mode === 'check-replayed-work') {
        const result = read('replayed-after-work.json');
        assert.equal(result.status, 'already-applied');
        assert.equal(result.currentHeads.prj, git(f.target, 'rev-parse', 'HEAD'));
        assert.notEqual(result.currentHeads.prj, read('first-head.json').prj);
        assert.deepEqual(tree(f.workspace), read('collect-before.json'));
    } else if (mode === 'check-collection') {
        const result = read('collected.json');
        const again = read('collected-again.json');
        assert.equal(result.status, 'collected');
        assert.equal(again.status, 'unchanged');
        assert.equal(again.collectionId, result.collectionId);
        assert.deepEqual(tree(f.workspace), read('collect-before.json'));
        const directory = mapped(result.directory);
        const full = fs.readFileSync(path.join(directory, 'prj', 'changes.patch'), 'utf8');
        const work = fs.readFileSync(path.join(directory, 'prj', 'work.patch'), 'utf8');
        assert.match(full, /sandbox-rounds/);
        assert.match(work, /Committed sandbox implementation/);
        assert.doesNotMatch(work, /sandbox-rounds/);
        assert.ok(fs.existsSync(path.join(directory, 'prj', 'history.bundle')));
        assert.equal(result.applicationTestsRun, false);
    } else if (mode === 'dirty') {
        write(f.target, 'src/original.txt', 'Uncommitted fixture edit\n');
    } else if (mode === 'clear-dirty') {
        write(f.target, 'src/original.txt', 'Committed sandbox implementation\n');
    } else if (mode === 'tamper-input') {
        commit(f.target, 'sandbox-rounds/TASK-1/R1/README.md', 'Unexpected committed input edit\n');
        write(root, 'tampered-before.json', JSON.stringify(tree(f.workspace)));
    } else if (mode === 'check-refused-tamper') {
        assert.deepEqual(tree(f.workspace), read('tampered-before.json'));
        const status = read('input-status.json');
        assert.equal(status.status, 'blocked');
        assert.ok(status.inputIssues.some(issue => issue.repository === 'prj' && issue.roundPath.endsWith('/R1')));
        const record = read('operator-state/pera-sandbox-tasks/TASK-1/record.json');
        assert.equal(Object.keys(record.plans).length, 2, 'Invalid retained input must not publish another plan.');
    } else throw new Error(`Unknown fixture operation: ${mode}`);
}
