'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');

const core = process.env.ROUNDS_CORE || '/opt/rounds.js';
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const environment = root => ({
    PATH: process.env.PATH,
    HOME: root,
    TMPDIR: root,
    LANG: 'C.UTF-8',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_TERMINAL_PROMPT: '0',
});

function git(root, ...args) {
    const result = spawnSync('git', ['-C', root, ...args], {
        encoding: 'utf8', env: environment(root), maxBuffer: 40 * 1024 * 1024,
    });
    assert.equal(result.status, 0, `Fixture Git command failed (${args[0]}): ${result.stderr}`);
    return result.stdout.trim();
}

function write(root, relative, content) {
    const file = path.join(root, relative);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, content);
    return file;
}

function repository(root) {
    fs.mkdirSync(root, { recursive: true });
    const template = path.join(root, 'empty-template');
    fs.mkdirSync(template);
    git(root, 'init', '--quiet', '-b', 'sandbox-fixture', `--template=${template}`);
    fs.rmdirSync(template);
    git(root, 'config', 'user.name', 'Round Fixture');
    git(root, 'config', 'user.email', 'round-fixture@example.invalid');
    write(root, '.gitignore', 'node_modules/\n.node-cache/\n.cache/\n');
    write(root, 'README.md', 'Canonical README remains unchanged.\n');
    write(root, 'src/original.txt', 'Canonical implementation remains unchanged.\n');
    git(root, 'add', '.');
    git(root, 'commit', '--quiet', '-m', 'Fixture baseline');
}

function createFixture(base) {
    fs.mkdirSync(base, { recursive: true, mode: 0o700 });
    const source = path.join(base, 'external source');
    const workspace = path.join(base, 'retained workspace');
    const target = path.join(workspace, 'prj');
    const documentation = path.join(workspace, 'Documentation');
    const state = path.join(base, 'state');
    const packets = path.join(base, 'packets');
    repository(source);
    repository(target);
    repository(documentation);
    fs.mkdirSync(state, { mode: 0o700 });
    fs.mkdirSync(packets);
    write(source, 'briefs/first brief.md', '# First committed review\n\nUse the retained caches.\n');
    write(source, 'briefs/second.txt', 'Second supporting text.\r\n');
    git(source, 'add', 'briefs');
    git(source, 'commit', '--quiet', '-m', 'External brief snapshot');
    const sourceHead = git(source, 'rev-parse', 'HEAD');
    const baseHead = git(target, 'rev-parse', 'HEAD');
    for (const repo of [target, documentation]) {
        for (const cache of ['node_modules', '.node-cache', '.cache']) {
            write(repo, `${cache}/sentinel`, `Retained ${cache}\n`);
        }
    }
    write(workspace, '.m2/repository/sentinel', 'Retained Maven cache\n');
    const fixture = { base, source, workspace, target, documentation, state, packets, sourceHead, baseHead };
    write(base, 'fixture.json', `${JSON.stringify(fixture, null, 2)}\n`);
    return fixture;
}

function fixture(t) {
    const root = path.join(process.cwd(), `round-case-${crypto.randomUUID()}`);
    const result = createFixture(root);
    t.after(() => fs.rmSync(root, { recursive: true, force: true }));
    return result;
}

function invoke(f, mode, options = {}) {
    const args = [core, mode, '--root', options.root || (mode === 'export' ? f.source : f.target),
        '--repository', options.repository || 'prj'];
    if (mode === 'export') {
        args.push('--ref', options.ref || 'HEAD', '--task', options.task || 'TASK_42',
            '--round', options.round || 'R1');
        for (const selected of options.paths || ['briefs/second.txt', 'briefs/first brief.md']) args.push('--path', selected);
    } else {
        args.push('--state', options.state || f.state, '--packet', options.packet || f.packet);
        if (options.head !== undefined) args.push('--expected-head', options.head);
    }
    const result = spawnSync(process.execPath, args, {
        cwd: f.base, env: { ...environment(f.base), ...options.env }, encoding: 'utf8',
        maxBuffer: 40 * 1024 * 1024,
    });
    return result;
}

function successful(result) {
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, '', 'Successful helper calls must not emit diagnostics.');
    return JSON.parse(result.stdout);
}

function exported(f, options = {}) {
    const result = invoke(f, 'export', options);
    const packet = successful(result);
    f.packet = write(f.packets, `${options.round || 'R1'}.json`, result.stdout);
    return packet;
}

function rejected(result) {
    assert.notEqual(result.status, 0, 'Operation unexpectedly succeeded.');
    assert.equal(result.stdout, '', 'A failed operation must not emit packet/document contents.');
    assert.ok(result.stderr.trim(), 'A failed operation must explain why.');
    return result.stderr;
}

function tree(root) {
    const entries = {};
    function visit(directory, prefix = '') {
        for (const name of fs.readdirSync(directory).sort()) {
            const file = path.join(directory, name);
            const relative = prefix ? `${prefix}/${name}` : name;
            const stat = fs.lstatSync(file);
            if (stat.isSymbolicLink()) entries[relative] = ['link', fs.readlinkSync(file)];
            else if (stat.isDirectory()) {
                entries[relative] = ['directory', stat.mode & 0o777];
                visit(file, relative);
            } else entries[relative] = ['file', stat.mode & 0o777, sha256(fs.readFileSync(file))];
        }
    }
    visit(root);
    return entries;
}

module.exports = { core, sha256, git, write, repository, createFixture, fixture, invoke, successful, exported, rejected, tree };
