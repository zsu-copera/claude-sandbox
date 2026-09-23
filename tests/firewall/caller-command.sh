#!/bin/bash
set -euo pipefail
R=/run/e1-test
name=${0##*/}
wait_for() {
    local file=$1
    for ((i=0; i<600; i++)); do
        [ ! -e "$file" ] || return 0
        "$R/real/sleep" 0.01
    done
    echo "caller fixture timed out waiting for ${file##*/}" >&2
    return 72
}
case "$name" in
    sudo)
        [ "${1:-}" = /usr/local/bin/init-firewall.sh ] && [ "${2:-}" = lockdown ] \
            || { echo "unexpected caller privileged command" >&2; exit 64; }
        count=0
        [ ! -e "$R/sudo-count" ] || count=$(< "$R/sudo-count")
        count=$((count + 1))
        printf '%s\n' "$count" > "$R/sudo-count"
        printf '%s\0' "$@" > "$R/sudo-$count"
        if [ "$(< "$R/scenario")" = initial-failure ]; then
            echo "injected initial firewall failure" >&2
            exit 73
        elif [ "$count" -gt 1 ]; then
            echo "injected caller refresh failure" >&2
            exit 71
        fi
        ;;
    sleep)
        [ "$*" = 900 ] || { echo "unexpected caller sleep" >&2; exit 64; }
        if [ ! -e "$R/sleep-count" ]; then
            : > "$R/sleep-count"
            wait_for "$R/cli-started"
        else
            wait_for "$R/cli-done"
            exit 75
        fi
        ;;
    curl)
        : > "$R/curl-called"
        [ "${!#}" = https://api.github.com/meta ] || { echo "unexpected caller curl URL" >&2; exit 64; }
        printf '{"web":["192.0.2.0/24"],"api":["198.51.100.0/24"]}\n'
        ;;
    claude|copilot)
        : > "$R/cli-called"
        if [ "${1:-}" = --version ]; then echo "E1 fake CLI"; exit 0; fi
        [ ! -e /workspace/.secrets ] && [ ! -e "$HOME/.m2/settings.xml" ] && [ ! -e "$HOME/.npmrc" ] \
            || { echo "fake CLI saw unpurged synthetic credentials" >&2; exit 76; }
        if [ "$name" = copilot ]; then
            [ -z "${GH_TOKEN+x}" ] && [ -z "${GITHUB_TOKEN+x}" ] \
                || { echo "fake CLI saw GH_TOKEN/GITHUB_TOKEN" >&2; exit 77; }
            [ "${COPILOT_GITHUB_TOKEN:-}" = github_pat_n3_synthetic_fixture ] \
                || { echo "fake CLI did not receive the PAT" >&2; exit 77; }
        fi
        printf '%s\0' "$@" > "$R/cli-arguments"
        : > "$R/cli-started"
        for ((i=0; i<600; i++)); do
            if grep -Fq '[firewall] WARN: allowlist refresh failed; restrictions retained.' "$R/launcher.log"; then
                : > "$R/cli-done"
                exit 0
            fi
            "$R/real/sleep" 0.01
        done
        echo "fake CLI never observed refresh failure warning" >&2
        exit 72
        ;;
    *) echo "unknown caller shim: $name" >&2; exit 64 ;;
esac
