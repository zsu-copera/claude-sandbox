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
    if (mode === 'context-inputs') {
        const handoff = { version: 1, briefs: { prj: [], Documentation: ['review.md'] },
            documents: [{ repository: 'Documentation', path: 'README.md', role: 'shared',
                reason: 'Both sides update the shared status document' }], retire: [], decisions: [] };
        const bytes = JSON.stringify(handoff);
        write(root, 'handoff.json', bytes);
        write(root, 'handoff-empty.json', '');
        write(root, 'handoff-multiple.json', '{}\n{}\n');
        const invalidUtf8 = Buffer.from(bytes);
        invalidUtf8[invalidUtf8.indexOf('Both sides')] = 0xff;
        write(root, 'handoff-utf8.json', invalidUtf8);
        write(root, 'handoff-nul.json', Buffer.concat([Buffer.from(bytes), Buffer.from([0])]));
        write(root, 'handoff-oversized.json', Buffer.alloc(1024 * 1024 + 1, 32));
        fs.chmodSync(write(root, 'handoff-permissive.json', bytes), 0o644);
        fs.symlinkSync('handoff.json', path.join(root, 'handoff-symlink.json'));
        const linked = write(root, 'handoff-link-source.json', bytes);
        fs.linkSync(linked, path.join(root, 'handoff-hardlink.json'));
        write(root, 'handoff-large-invalid.json', JSON.stringify({ ...handoff, extra: 'x'.repeat(200000) }));
    } else if (mode === 'context-check-refusals') {
        const record = read('operator-state/pera-sandbox-tasks/TASK-1/record.json');
        assert.equal(record.version, 1);
        assert.deepEqual(record.plans, {});
        assert.equal(record.activePlan, null);
        const before = read('before.json');
        assert.deepEqual(tree(f.workspace), before.workspace);
        assert.deepEqual(tree(f.source), before.source);
        assert.deepEqual(tree(docsSource), before.documentation);
    } else if (mode === 'context-alternative') {
        write(root, 'handoff-first-choice.json', fs.readFileSync(path.join(root, 'handoff.json')));
        const handoff = read('handoff.json');
        handoff.documents[0].reason = 'Alternative pre-approval context';
        write(root, 'handoff.json', JSON.stringify(handoff));
    } else if (mode === 'context-restore-choice') {
        write(root, 'handoff.json', fs.readFileSync(path.join(root, 'handoff-first-choice.json')));
    } else if (mode === 'context-check-reselected') {
        const first = read('context-plan.json');
        const alternative = read('context-alternative-plan.json');
        const reselected = read('context-reselected.json');
        const record = read('operator-state/pera-sandbox-tasks/TASK-1/record.json');
        assert.notEqual(first.planId, alternative.planId);
        assert.equal(reselected.planId, first.planId);
        assert.equal(record.activePlan, first.planId);
        assert.equal(record.plans[first.planId].status, 'pending');
        assert.equal(record.plans[alternative.planId].status, 'superseded');
        assert.equal(record.lastContext, null);
        assert.deepEqual(tree(f.workspace), read('before.json').workspace);
    } else if (mode === 'context-prior-work') {
        commit(f.target, 'src/original.txt', 'Previously collected implementation\n');
    } else if (mode === 'context-metadata') {
        const first = read('context-plan.json');
        assert.equal(first.status, 'approval-required');
        assert.equal(first.round, 'R1');
        assert.equal(first.repositories.prj.action, 'preserve');
        assert.ok(first.context);
        assert.match(JSON.stringify(first.context), /sandbox-rounds\/TASK-1\/R1\/files\/README\.md/);
        const record = read('operator-state/pera-sandbox-tasks/TASK-1/record.json');
        assert.equal(record.version, 2);
        assert.deepEqual(record.config, read('config.json'));
        write(root, 'context-before-metadata.json', JSON.stringify({ record, workspace: tree(f.workspace) }));
        const handoff = read('handoff.json');
        handoff.documents[0].reason = 'Keep the same inputs under an amended ownership explanation';
        write(root, 'handoff.json', JSON.stringify(handoff));
    } else if (mode === 'context-corrupt-original') {
        const plan = read('context-metadata-plan.json');
        assert.equal(plan.status, 'approval-required');
        assert.equal(plan.round, null);
        assert.equal(plan.repositories.prj.action, 'preserve');
        assert.equal(plan.repositories.Documentation.action, 'preserve');
        write(root, 'handoff-saved.json', fs.readFileSync(path.join(root, 'handoff.json')));
        write(root, 'handoff.json', '{"version":999}\n');
    } else if (mode === 'context-check-metadata') {
        const before = read('context-before-metadata.json');
        const record = read('operator-state/pera-sandbox-tasks/TASK-1/record.json');
        assert.deepEqual(tree(f.workspace), before.workspace);
        assert.deepEqual(record.executionHeads, before.record.executionHeads);
        assert.deepEqual(record.collectionHeads, before.record.collectionHeads);
        assert.equal(record.lastRound, before.record.lastRound);
        assert.equal(read('context-metadata-applied.json').status, 'applied');
    } else if (mode === 'context-omit') {
        const first = read('context-collection-first.json');
        const second = read('context-collection-metadata.json');
        assert.notEqual(first.collectionId, second.collectionId);
        assert.deepEqual(first.manifest.binding.heads, second.manifest.binding.heads);
        assert.notEqual(first.manifest.binding.context.revision, second.manifest.binding.context.revision);
        assert.notEqual(first.manifest.binding.context.planId, second.manifest.binding.context.planId);
        assert.match(fs.readFileSync(path.join(mapped(second.directory), 'prj/work.patch'), 'utf8'), /Previously collected implementation/);
        const handoff = read('handoff-saved.json');
        handoff.documents = [];
        write(root, 'handoff.json', JSON.stringify(handoff));
        commit(docsSource, 'README.md', 'Host audit amendment\n');
        write(root, 'context-before-decision.json', JSON.stringify({
            record: read('operator-state/pera-sandbox-tasks/TASK-1/record.json'), workspace: tree(f.workspace),
        }));
    } else if (mode === 'context-check-needs-decision') {
        const result = read('context-needs-decision.json');
        assert.equal(result.status, 'needs-decision');
        assert.ok(!result.planId);
        assert.match(JSON.stringify(result), /README\.md/);
        const before = read('context-before-decision.json');
        assert.deepEqual(tree(f.workspace), before.workspace);
        assert.deepEqual(read('operator-state/pera-sandbox-tasks/TASK-1/record.json'), before.record);
    } else if (mode === 'context-decide') {
        const handoff = read('handoff.json');
        handoff.decisions = [{ repository: 'Documentation', path: 'README.md',
            action: 'reconcile-in-sandbox', reason: 'Preserve host amendments alongside sandbox additions' }];
        write(root, 'handoff.json', JSON.stringify(handoff));
    } else if (mode === 'context-work') {
        const plan = read('context-second-plan.json');
        assert.equal(plan.round, 'R2');
        assert.ok(plan.repositories.Documentation.inputs.some(input => input.path === 'README.md'));
        commit(f.documentation, 'README.md', 'Host audit amendment\nSandbox write-back\n');
    } else if (mode === 'context-before-replay') {
        write(root, 'context-before-replay.json', JSON.stringify(read('operator-state/pera-sandbox-tasks/TASK-1/record.json')));
    } else if (mode === 'context-check-final') {
        const status = read('context-status.json');
        assert.ok(status.context);
        assert.match(JSON.stringify(status.context), /sandbox-only/);
        const collected = read('context-collection-work.json');
        assert.equal(collected.status, 'collected');
        assert.equal(collected.manifest.binding.heads.Documentation, git(f.documentation, 'rev-parse', 'HEAD'));
        const directory = mapped(collected.directory);
        assert.match(fs.readFileSync(path.join(directory, 'Documentation/work.patch'), 'utf8'), /Sandbox write-back/);
        const replay = read('context-replay.json');
        assert.equal(replay.status, 'already-applied');
        assert.deepEqual(read('operator-state/pera-sandbox-tasks/TASK-1/record.json'), read('context-before-replay.json'));
    } else if (mode === 'observation-dirty') {
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
        const alternative = read('alternative-plan.json');
        const reselected = read('reselected.json');
        const record = read('operator-state/pera-sandbox-tasks/TASK-1/record.json');
        assert.notEqual(alternative.planId, plan.planId);
        assert.equal(reselected.planId, plan.planId);
        assert.equal(record.activePlan, plan.planId);
        assert.equal(record.plans[plan.planId].status, 'pending');
        assert.equal(record.plans[alternative.planId].status, 'superseded');
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
        write(root, 'tampered-before-plans.json', JSON.stringify(read('operator-state/pera-sandbox-tasks/TASK-1/record.json').plans));
        commit(f.target, 'sandbox-rounds/TASK-1/R1/README.md', 'Unexpected committed input edit\n');
        write(root, 'tampered-before.json', JSON.stringify(tree(f.workspace)));
    } else if (mode === 'check-refused-tamper') {
        assert.deepEqual(tree(f.workspace), read('tampered-before.json'));
        const status = read('input-status.json');
        assert.equal(status.status, 'blocked');
        assert.ok(status.inputIssues.some(issue => issue.repository === 'prj' && issue.roundPath.endsWith('/R1')));
        const record = read('operator-state/pera-sandbox-tasks/TASK-1/record.json');
        assert.deepEqual(record.plans, read('tampered-before-plans.json'), 'Invalid retained input must not alter the plan registry.');
    } else throw new Error(`Unknown fixture operation: ${mode}`);
}
