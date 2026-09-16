'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { validateConfig } = require('./tasks.js');
const { documentPaths, observeDocuments } = require('/opt/rounds.js');

function gitBytes(root, args) {
    const result = spawnSync('git', ['-c', `safe.directory=${root}`, '-c', 'core.fsmonitor=false',
        '-c', 'core.hooksPath=/dev/null', '-c', 'core.untrackedCache=false', '-C', root, ...args], {
        maxBuffer: 32 * 1024 * 1024,
        env: { PATH: process.env.PATH, HOME: '/nonexistent', GIT_CONFIG_NOSYSTEM: '1',
            GIT_CONFIG_GLOBAL: '/dev/null', GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1',
            GIT_TERMINAL_PROMPT: '0', GIT_NO_LAZY_FETCH: '1', LANG: 'C.UTF-8' },
    });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`Read-only Git inspection failed (status ${result.status}): ${result.stderr.toString('utf8').trim()}`);
    return result.stdout;
}

function inspectSource(readGit, ref, paths = []) {
    if (!Array.isArray(paths)) throw new Error('Source document paths must be an array');
    if (paths.length) paths = documentPaths(paths);
    // Reuse the exact public ref validator without permitting ambient HEAD.
    validateConfig({ version: 1, task: 'check', workspace: '/workspace', image: 'check', profiles: [],
        repositories: Object.fromEntries(['prj', 'Documentation'].map(repo => [repo,
            { source: '/repo', ref, auditBase: '1'.repeat(40), briefs: [] }])) });
    const git = (...args) => readGit(args).toString('utf8').trim();
    git('check-ref-format', ref);
    const head = git('rev-parse', '--verify', `${ref}^{commit}`);
    if (git('rev-parse', '--verify', ref) !== head) throw new Error('Source branch does not point directly to a commit');
    if (!paths.length) return { ref, head };
    const documents = observeDocuments(readGit, head, paths);
    if (git('rev-parse', '--verify', ref) !== head) throw new Error('Source branch changed during document inspection');
    return { ref, head, documents };
}

function main(argv, root = '/repo') {
    const [mode, ...args] = argv;
    const metadata = fs.lstatSync(path.join(root, '.git'));
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw new Error('Only ordinary .git directories are supported');
    for (const name of ['commondir', 'shallow', 'info/grafts', 'objects/info/alternates']) {
        if (fs.existsSync(path.join(root, '.git', name))) throw new Error('Linked, shallow or alternate-object repositories are unsupported');
    }
    const readGit = args => gitBytes(root, args);
    const git = (...args) => readGit(args).toString('utf8').trim();
    if (mode === 'source') {
        const [ref, ...paths] = args;
        return inspectSource(readGit, ref, paths);
    } else if (mode === 'import-head') {
        const [head, base, roundPath] = args;
        if (args.length !== 3 || !/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(head)
            || !/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(base)
            || !/^sandbox-rounds\/[A-Za-z0-9][A-Za-z0-9_-]{0,63}\/R[0-9]+$/.test(roundPath)) throw new Error('Invalid import identity');
        const parents = git('rev-list', '--parents', '-n', '1', head).split(' ');
        if (parents.length !== 2 || parents[1] !== base) throw new Error('HEAD is not the exact approved import child; manual recovery required');
        const changed = git('diff-tree', '--no-ext-diff', '--no-textconv', '--no-renames',
            '--no-commit-id', '--name-only', '-r', '-z', base, head).split('\0').filter(Boolean);
        if (!changed.length || changed.some(name => !name.startsWith(`${roundPath}/`))) {
            throw new Error('Approved import child contains unrelated changes; manual recovery required');
        }
        return { status: 'exact-import' };
    } else throw new Error('Unknown read-only inspection mode');
}

if (require.main === module) {
    try {
        process.stdout.write(`${JSON.stringify(main(process.argv.slice(2)))}\n`);
    } catch (error) {
        process.stderr.write(`sandbox-task: ${error.message}\n`);
        process.exitCode = 1;
    }
}

module.exports = { main, inspectSource };
