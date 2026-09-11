'use strict';

// Test-only preload, mounted read-only. The production helper has no fault hooks.
const fs = require('node:fs');
const path = require('node:path');
const fault = process.env.ROUND_FIXTURE_FAULT;
const original = {
    renameSync: fs.renameSync,
    linkSync: fs.linkSync,
    writeFileSync: fs.writeFileSync,
    copyFileSync: fs.copyFileSync,
    unlinkSync: fs.unlinkSync,
};
const kill = () => process.kill(process.pid, 'SIGKILL');

fs.renameSync = function (source, destination, ...rest) {
    const publish = path.basename(String(source)).startsWith('round-stage-')
        && String(destination).includes('/sandbox-rounds/');
    const index = String(destination).endsWith('/.git/index');
    if ((fault === 'publish' && publish) || (fault === 'index' && index)) {
        throw new Error('Fixture-induced interruption');
    }
    const result = original.renameSync.call(this, source, destination, ...rest);
    if (fault === 'published' && publish) kill();
    if (path.basename(String(destination)) === 'pending.json') {
        const journal = JSON.parse(fs.readFileSync(destination, 'utf8'));
        if ((fault === 'journal-preparing' && journal.phase === 'preparing')
            || (fault === 'journal-updating-refs' && journal.phase === 'updating-refs')) kill();
    }
    if (fault === 'index-prepared-rename' && path.basename(String(source)).startsWith('round-index-')
        && String(destination).endsWith('/.git/index.lock')) kill();
    return result;
};

fs.writeFileSync = function (file, bytes, ...rest) {
    const result = original.writeFileSync.call(this, file, bytes, ...rest);
    if (fault === 'owner-created' && path.basename(String(file)).startsWith('round-owner-')) kill();
    return result;
};

fs.linkSync = function (source, destination, ...rest) {
    const result = original.linkSync.call(this, source, destination, ...rest);
    if ((fault === 'index-lock-created' && String(destination).endsWith('/.git/index.lock'))
        || (fault === 'head-lock-created' && String(destination).endsWith('/.git/HEAD.lock'))) kill();
    return result;
};

fs.copyFileSync = function (source, destination, ...rest) {
    if (fault === 'index-partial-copy' && path.basename(String(destination)).startsWith('round-index-')) {
        const bytes = fs.readFileSync(source);
        original.writeFileSync.call(fs, destination, bytes.subarray(0, 17), { flag: 'wx', mode: 0o600 });
        kill();
    }
    return original.copyFileSync.call(this, source, destination, ...rest);
};

fs.unlinkSync = function (file, ...rest) {
    const result = original.unlinkSync.call(this, file, ...rest);
    if (fault === 'rollback-unlink' && /\/\.git\/round-stage-[^/]+\//.test(String(file))) kill();
    return result;
};
