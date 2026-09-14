'use strict';

const fs = require('node:fs');
const { spawnSync } = require('node:child_process');
const { validateConfig } = require('./tasks.js');

function git(...args) {
    const result = spawnSync('git', ['-c', 'safe.directory=/repo', '-c', 'core.fsmonitor=false',
        '-c', 'core.hooksPath=/dev/null', '-c', 'core.untrackedCache=false', '-C', '/repo', ...args], {
        encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
        env: { PATH: process.env.PATH, HOME: '/nonexistent', GIT_CONFIG_NOSYSTEM: '1',
            GIT_CONFIG_GLOBAL: '/dev/null', GIT_OPTIONAL_LOCKS: '0', GIT_NO_REPLACE_OBJECTS: '1',
            GIT_TERMINAL_PROMPT: '0', GIT_NO_LAZY_FETCH: '1', LANG: 'C.UTF-8' },
    });
    if (result.status !== 0) throw new Error(`Read-only Git inspection failed: ${result.stderr.trim()}`);
    return result.stdout.trim();
}
try {
    const [mode, ...args] = process.argv.slice(2);
    const metadata = fs.lstatSync('/repo/.git');
    if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw new Error('Only ordinary .git directories are supported');
    for (const name of ['commondir', 'shallow', 'info/grafts', 'objects/info/alternates']) {
        if (fs.existsSync(`/repo/.git/${name}`)) throw new Error('Linked, shallow or alternate-object repositories are unsupported');
    }
    if (mode === 'source') {
        const [ref] = args;
        // Reuse the exact public ref validator without permitting ambient HEAD.
        validateConfig({ version: 1, task: 'check', workspace: '/workspace', image: 'check', profiles: [],
            repositories: Object.fromEntries(['prj', 'Documentation'].map(repo => [repo,
                { source: '/repo', ref, auditBase: '1'.repeat(40), briefs: [] }])) });
        git('check-ref-format', ref);
        const head = git('rev-parse', '--verify', `${ref}^{commit}`);
        if (git('rev-parse', '--verify', ref) !== head) throw new Error('Source branch does not point directly to a commit');
        process.stdout.write(`${JSON.stringify({ ref, head })}\n`);
    } else if (mode === 'import-head') {
        const [head, base, roundPath] = args;
        if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(head)
            || !/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(base)
            || !/^sandbox-rounds\/[A-Za-z0-9][A-Za-z0-9_-]{0,63}\/R[0-9]+$/.test(roundPath)) throw new Error('Invalid import identity');
        const parents = git('rev-list', '--parents', '-n', '1', head).split(' ');
        if (parents.length !== 2 || parents[1] !== base) throw new Error('HEAD is not the exact approved import child; manual recovery required');
        const changed = git('diff-tree', '--no-ext-diff', '--no-textconv', '--no-renames',
            '--no-commit-id', '--name-only', '-r', '-z', base, head).split('\0').filter(Boolean);
        if (!changed.length || changed.some(name => !name.startsWith(`${roundPath}/`))) {
            throw new Error('Approved import child contains unrelated changes; manual recovery required');
        }
        process.stdout.write('{"status":"exact-import"}\n');
    } else throw new Error('Unknown read-only inspection mode');
} catch (error) {
    process.stderr.write(`sandbox-task: ${error.message}\n`);
    process.exitCode = 1;
}
