#!/bin/bash
# Installed only in a root-owned test PATH. Real kernel commands remain underneath.
set -uo pipefail
R=/run/e1-test
name=${0##*/}
# A killed test shim must not keep the production parent's flock alive.
exec 9>&-
printf '%s %s\n' "$name" "$*" >> "$R/trace"
if [ "$name" = dig ]; then
    if [ -e "$R/dig-fail" ]; then echo "injected DNS command failure" >&2; exit 71; fi
    case "${!#}" in
        provider.test) cat "$R/answers" ;;
        secondary.test) cat "$R/secondary" ;;
        evil.test) cat "$R/forbidden" ;;
        *) echo "unexpected synthetic DNS name: ${!#}" >&2; exit 64 ;;
    esac
    exit
fi
if [ "$name" = curl ]; then
    case "${!#}" in
        https://provider.test|https://secondary.test)
            if [ -e "$R/smoke-positive-fail" ]; then echo "injected positive smoke failure" >&2; exit 71; fi
            target=$(head -n 1 "$R/answers")
            ;;
        https://example.com)
            if [ -e "$R/smoke-negative-success" ]; then exit 0; fi
            target=$(< "$R/forbidden")
            ;;
        *) echo "unexpected smoke URL: ${!#}" >&2; exit 64 ;;
    esac
    exec "$R/real/curl" --noproxy '*' -s --connect-timeout 1 -m 2 -o /dev/null "http://$target:443"
fi
if [ "$name" = ipset ] && [ "${1:-}" = create ] && [ "${2:-}" = claude-probe ] \
    && [ -e "$R/no-ipset" ]; then
    echo "test-only ipset probe unavailability" >&2
    exit 71
fi

point=""
case "$name $*" in
    "ipset create claude-allowed-new "*) point=stage-create ;;
    "ipset add claude-allowed-new "*) point=stage-add ;;
    "ipset swap claude-allowed-new claude-allowed") point=activation ;;
    "ipset destroy claude-allowed-new") point=cleanup ;;
    "iptables -R CLAUDE_HTTPS 1 -j "*) point=activation ;;
    "iptables -A CLAUDE_ALLOW_"*) point=stage-add ;;
    "iptables -A INPUT -m state "*) point=partial-initial ;;
esac
if [ "$name" = iptables ] && [ "${1:-}" = -F ] && [ -e "$R/stage-chain" ]; then
    [ "${2:-}" != "$(< "$R/stage-chain")" ] || point=stage-create
    [ "${2:-}" != "$(< "$R/old-chain")" ] || point=cleanup
fi
matched=0
if [ -e "$R/armed" ] && [ "$point" = "$(< "$R/point")" ]; then
    remaining=$(< "$R/remaining")
    if [ "$remaining" -gt 0 ]; then
        printf '%s\n' "$((remaining - 1))" > "$R/remaining"
    else
        matched=1
        rm -- "$R/armed"
    fi
fi
barrier() {
    printf '%s\n' "$BASHPID" > "$R/barrier-pid"
    : > "$R/reached"
    for ((i=0; i<2000; i++)); do
        [ ! -e "$R/release" ] || return 0
        sleep 0.01
    done
    echo "test barrier timed out" >&2
    return 72
}
if [ "$matched" -eq 1 ]; then
    action=$(< "$R/action")
    case "$action" in
        fail) echo "injected $name $point failure" >&2; exit 71 ;;
        before) barrier || exit $? ;;
        after) ;;
        *) echo "invalid test action: $action" >&2; exit 64 ;;
    esac
fi
"$R/real/$name" "$@"
status=$?
[ "$status" -eq 0 ] || exit "$status"
if [ "$matched" -eq 1 ] && [ "$action" = after ]; then barrier || exit $?; fi
