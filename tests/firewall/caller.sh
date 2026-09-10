#!/bin/bash
# The only source input is the current launcher on stdin, never an agent install.
set -Eeuo pipefail
R=/run/e1-test
CLI=${1:?fake CLI name}
SCENARIO=${2:?caller scenario}
umask 077
mkdir -p -m 700 "$R/bin" "$R/real" "$R/home/.m2" "$R/home/.copilot"
cp /dev/stdin "$R/launcher.sh"
printf '%s\n' "$SCENARIO" > "$R/scenario"
ln -s "$(command -v sleep)" "$R/real/sleep"
for command in "sudo" sleep curl claude copilot; do
    cp /opt/e1-fixtures/caller-command.sh "$R/bin/$command"
    chmod 700 "$R/bin/$command"
done
export HOME="$R/home" PATH="$R/bin:$PATH"
die() { echo "ASSERT: $*" >&2; cat "$R/launcher.log" >&2; exit 1; }
[ "$(command -v "$CLI")" = "$R/bin/$CLI" ] || die "real agent CLI must never run"
[ ! -e /workspace/.agent-cli ] || die "unexpected image-staged CLI, refusing to launch"
mkdir -p /workspace/.secrets
printf 'synthetic fixture\n' > /workspace/.secrets/e1-fixture
printf 'synthetic fixture\n' > "$HOME/.m2/settings.xml"
printf 'synthetic fixture\n' > "$HOME/.npmrc"
printf '{}\n' > "$HOME/.copilot/settings.json"

status=0
bash "$R/launcher.sh" --e1-argument 'value with spaces' > "$R/launcher.log" 2>&1 || status=$?
if [ "$SCENARIO" = initial-failure ]; then
    [ "$status" -eq 73 ] || die "initial firewall failure did not propagate: $status"
    [ ! -e "$R/cli-called" ] || die "CLI ran despite initial firewall failure"
    [ ! -e "$R/sleep-count" ] || die "refresh loop started despite initial firewall failure"
    [ -f /workspace/.secrets/e1-fixture ] && [ -f "$HOME/.m2/settings.xml" ] && [ -f "$HOME/.npmrc" ] \
        || die "credentials purged before initial firewall success"
else
    [ "$status" -eq 0 ] || die "refresh failure prevented clean fake CLI exit: $status"
    [ -f "$R/cli-done" ] || die "fake CLI did not continue through refresh failure"
    [ ! -e /workspace/.secrets ] && [ ! -e "$HOME/.m2/settings.xml" ] && [ ! -e "$HOME/.npmrc" ] \
        || die "successful initial lockdown did not precede purge"
    grep -Fq 'injected caller refresh failure' "$R/launcher.log" || die "firewall stderr was swallowed"
    grep -Fq '[firewall] WARN: allowlist refresh failed; restrictions retained.' "$R/launcher.log" \
        || die "refresh failure warning missing"
    cmp "$R/sudo-1" "$R/sudo-2" || die "refresh changed initial firewall arguments"
    mapfile -d '' -t arguments < "$R/cli-arguments"
    [ "${arguments[-2]}" = --e1-argument ] && [ "${arguments[-1]}" = 'value with spaces' ] \
        || die "caller arguments were not preserved"
fi
