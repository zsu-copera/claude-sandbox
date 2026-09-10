#!/bin/bash
set -Eeuo pipefail
R=/run/e1-test
FIX=/opt/e1-fixtures
MODE=${1:?backend or peer}
SUBNET=${2:?synthetic subnet}
CASE=${3:-}
OLD="$SUBNET.2"
NEW="$SUBNET.3"
FORBIDDEN="$SUBNET.4"
EXTRA="$SUBNET.5"
FW=/usr/local/bin/init-firewall.sh
STATE=/run/claude-firewall
COMMITTED=/run/claude-lockdown-domains
umask 077
mkdir -p -m 700 "$R"

die() { echo "ASSERT: $*" >&2; exit 1; }
no_external_route() {
    node "$FIX/traffic.js" topology "$SUBNET"
}
wait_file() {
    local path=$1
    for ((i=0; i<1000; i++)); do
        [ ! -e "$path" ] || return 0
        sleep 0.01
    done
    die "timed out waiting for ${path##*/}"
}
probe() { node "$FIX/traffic.js" probe "$1" "${3:-443}" "$2"; }
if [ "$MODE" = peer ]; then
    no_external_route
    exec node "$FIX/traffic.js" server 0.0.0.0 443 "$R/peer-ready"
elif [ "$MODE" = peer-ready ]; then
    wait_file "$R/peer-ready"
    probe 127.0.0.1 allow
    exit
fi

trap 'status=$?; echo "scenario $MODE/$CASE failed (status $status)" >&2; for file in "$R/fw.log" "$R/worker.log" "$R/trace"; do if [ -f "$file" ]; then echo "--- ${file##*/}" >&2; tail -n 35 "$file" >&2; fi; done; exit "$status"' ERR
no_external_route
mkdir -m 700 "$R/bin" "$R/real"
for command in iptables ipset dig curl; do
    path=$(command -v "$command") || die "missing existing image command: $command"
    ln -s "$path" "$R/real/$command"
    cp "$FIX/command.sh" "$R/bin/$command"
    chmod 700 "$R/bin/$command"
done
if [ "$CASE" = prerequisite ]; then
    if ! "$R/real/iptables" -N E1_REAL_PROBE; then
        echo "real iptables unavailable in the disposable NET_ADMIN namespace"
        exit 77
    fi
    "$R/real/iptables" -X E1_REAL_PROBE
    if [ "$MODE" = ipset ]; then
        if ! "$R/real/ipset" create e1-real-probe hash:net; then
            echo "real ipset unavailable in the disposable NET_ADMIN namespace"
            exit 77
        fi
        "$R/real/ipset" destroy e1-real-probe
    fi
    probe "$FORBIDDEN" allow
    exit
fi
[ "$MODE" != per-ip ] || : > "$R/no-ipset"
export PATH="$R/bin:$PATH"
printf '%s\n' "$OLD" > "$R/answers"
printf '%s\n' "$OLD" > "$R/secondary"
printf '%s\n' "$FORBIDDEN" > "$R/forbidden"
node "$FIX/traffic.js" server 127.0.0.1 8080 "$R/loop-ready" &
wait_file "$R/loop-ready"

real_tables() { "$R/real/iptables" "$@"; }
fw() { bash "$FW" "$@" > "$R/fw.log" 2>&1; }
expect_status() {
    local expected=$1 actual=0
    shift
    "$@" || actual=$?
    [ "$actual" -eq "$expected" ] || die "expected exit $expected, got $actual: $*"
}
expect_failure() {
    local status=0
    "$@" || status=$?
    [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || die "expected explicit failure, got $status: $*"
}
skeleton() {
    real_tables -S | grep -E '^(-P (INPUT|OUTPUT|FORWARD) |-(N|A) (INPUT|OUTPUT|FORWARD|CLAUDE_LOCKDOWN)( |$))'
}
live() {
    if [ "$MODE" = ipset ]; then
        "$R/real/ipset" save claude-allowed
    else
        local active
        active=$(real_tables -S CLAUDE_HTTPS | awk '$1=="-A" { print $4 }')
        real_tables -S CLAUDE_HTTPS
        real_tables -S "$active"
    fi
}
guarded() {
    expect_status 3 fw open
    expect_failure fw lockdown provider.test
}
locked() {
    for chain in INPUT OUTPUT FORWARD; do
        real_tables -S | grep -qx -- "-P $chain DROP" || die "$chain policy is not DROP"
    done
    real_tables -n -L CLAUDE_LOCKDOWN >/dev/null
    [ "$(stat -c '%u:%g:%a' "$COMMITTED")" = 0:0:600 ] || die "committed owner/mode"
    [ "$(stat -c '%u:%g:%a' "$STATE")" = 0:0:700 ] || die "state directory owner/mode"
    [ "$(cat "$STATE/backend")" = "$MODE" ] || die "wrong real backend selected"
    [ ! -e "$STATE/installing" ] || die "installing marker not published"
}
initial() {
    fw open
    probe "$FORBIDDEN" allow
    fw lockdown provider.test secondary.test
    locked
    expect_status 3 fw open
    printf 'provider.test\nsecondary.test\n' > "$R/expected-domains"
    cmp "$COMMITTED" "$R/expected-domains"
    skeleton > "$R/skeleton"
    live > "$R/live"
    probe "$OLD" allow
    probe "$FORBIDDEN" deny
    probe 127.0.0.1 allow 8080
}
unchanged() {
    skeleton > "$R/observed"
    cmp "$R/skeleton" "$R/observed"
    live > "$R/observed"
    cmp "$R/live" "$R/observed"
    cmp "$COMMITTED" "$R/expected-domains"
    probe "$OLD" allow
    probe "$NEW" deny
    probe "$FORBIDDEN" deny
}
new_active() {
    skeleton > "$R/observed"
    cmp "$R/skeleton" "$R/observed"
    cmp "$COMMITTED" "$R/expected-domains"
    probe "$NEW" allow
    probe "$OLD" deny
    probe "$FORBIDDEN" deny
    locked
}
new_answers() {
    printf '%s\n' "$NEW" > "$R/answers"
    printf '%s\n' "$NEW" > "$R/secondary"
}
arm() {
    local point=$1 action=$2
    rm -f -- "$R/armed" "$R/reached" "$R/release" "$R/barrier-pid"
    if [ "$MODE" = per-ip ] && [ -s "$STATE/backend" ]; then
        local active inactive
        active=$(real_tables -S CLAUDE_HTTPS | awk '$1=="-A" { print $4 }')
        inactive=CLAUDE_ALLOW_A
        [ "$active" != CLAUDE_ALLOW_A ] || inactive=CLAUDE_ALLOW_B
        printf '%s\n' "$active" > "$R/old-chain"
        printf '%s\n' "$inactive" > "$R/stage-chain"
    fi
    printf '%s\n' "$point" > "$R/point"
    printf '%s\n' "$action" > "$R/action"
    printf '%s\n' "${3:-0}" > "$R/remaining"
    : > "$R/armed"
}
start_watch() {
    node "$FIX/traffic.js" watch "$FORBIDDEN" "$R/stop-watch" "$R/traffic.json" > "$R/watch.log" 2>&1 &
    watcher=$!
}
stop_watch() {
    : > "$R/stop-watch"
    wait "$watcher"
    node "$FIX/traffic.js" report "$R/traffic.json"
}

case "$CASE" in
    preflight-first)
        fw open
        real_tables -S > "$R/before"
        expect_status 2 fw
        expect_status 2 fw invalid
        expect_status 2 fw open extra
        for bad in '-option' '999.1.2.3/24' '10.0.0.1/33' 'bad/domain'; do
            expect_failure fw lockdown "$bad"
        done
        : > "$R/secondary"
        expect_failure fw lockdown provider.test secondary.test
        real_tables -S > "$R/after"
        cmp "$R/before" "$R/after"
        [ ! -e "$STATE/installing" ] && [ ! -e "$COMMITTED" ] || die "DNS failure left durable initialization state"
        fw open
        printf '%s\n' "$OLD" > "$R/secondary"
        fw lockdown provider.test secondary.test
        locked
        ;;
    state-pending|state-kernel|state-backend-only)
        fw open
        if [ "$CASE" = state-pending ]; then
            printf 'provider.test\n' > "$STATE/installing"
        elif [ "$CASE" = state-backend-only ]; then
            printf '%s\n' "$MODE" > "$STATE/backend"
        else
            real_tables -N CLAUDE_LOCKDOWN
        fi
        real_tables -S > "$R/before"
        guarded
        real_tables -S > "$R/after"
        cmp "$R/before" "$R/after"
        ;;
    partial-initial)
        fw open
        arm partial-initial fail
        expect_failure fw lockdown provider.test
        [ -s "$STATE/installing" ] && [ ! -e "$COMMITTED" ] || die "partial installation state missing"
        real_tables -n -L CLAUDE_LOCKDOWN >/dev/null
        for chain in INPUT OUTPUT FORWARD; do real_tables -S | grep -qx -- "-P $chain DROP"; done
        guarded
        ;;
    cidr-only)
        fw lockdown "$OLD/32"
        locked
        probe "$OLD" allow
        probe "$FORBIDDEN" deny
        if grep -q '^dig ' "$R/trace"; then die "CIDR-only attempted DNS"; fi
        if grep -q '^curl .*https://provider.test' "$R/trace"; then die "CIDR-only positive probe"; fi
        fw lockdown "$FORBIDDEN/32"
        probe "$OLD" allow
        probe "$FORBIDDEN" deny
        ;;
    smoke-initial)
        : > "$R/smoke-positive-fail"
        expect_failure fw lockdown provider.test
        locked
        expect_status 3 fw open
        probe "$FORBIDDEN" deny
        ;;
    *)
        initial
        case "$CASE" in
            normal)
                new_answers
                fw lockdown evil.test
                new_active
                start_watch
                for ((i=0; i<12; i++)); do
                    address=$OLD
                    [ "$((i % 2))" -eq 0 ] || address=$NEW
                    printf '%s\n%s\n' "$address" "$address" > "$R/answers"
                    printf '%s\n' "$address" > "$R/secondary"
                    fw lockdown evil.test
                done
                stop_watch
                new_active
                ;;
            preflight-refresh)
                : > "$R/secondary"
                expect_failure fw lockdown provider.test secondary.test
                unchanged
                printf '999.2.3.4\n' > "$R/secondary"
                expect_failure fw lockdown provider.test secondary.test
                unchanged
                : > "$R/dig-fail"
                expect_failure fw lockdown provider.test secondary.test
                unchanged
                ;;
            stage-create|stage-add|activation|cleanup)
                new_answers
                if [ "$CASE" = stage-add ]; then
                    printf '%s\n%s\n' "$NEW" "$EXTRA" > "$R/answers"
                    arm "$CASE" fail 1
                else
                    arm "$CASE" fail
                fi
                expect_failure fw lockdown provider.test secondary.test
                [ ! -e "$R/armed" ] || die "failure injection was not reached"
                grep -q 'injected .* failure' "$R/fw.log" || die "injected error was not surfaced"
                if [ "$CASE" = cleanup ]; then new_active; else unchanged; fi
                fw lockdown provider.test secondary.test
                new_active
                ;;
            concurrency)
                new_answers
                arm activation before
                start_watch
                bash "$FW" lockdown provider.test secondary.test > "$R/worker.log" 2>&1 &
                worker=$!
                wait_file "$R/reached"
                unchanged
                dig_before=$(grep -c '^dig ' "$R/trace")
                bash "$FW" open > "$R/open.log" 2>&1 &
                opener=$!
                bash "$FW" lockdown evil.test > "$R/second.log" 2>&1 &
                second=$!
                sleep 0.3
                kill -0 "$opener"
                kill -0 "$second"
                [ "$(grep -c '^dig ' "$R/trace")" = "$dig_before" ] || die "second refresh bypassed lock"
                expect_status 1 flock -n "$STATE/lock" true
                : > "$R/release"
                wait "$worker"
                expect_status 3 wait "$opener"
                wait "$second"
                stop_watch
                new_active
                ;;
            term-before|term-after|kill-before|kill-after)
                new_answers
                arm activation "${CASE##*-}"
                start_watch
                bash "$FW" lockdown provider.test secondary.test > "$R/worker.log" 2>&1 &
                worker=$!
                wait_file "$R/reached"
                if [[ "$CASE" == *-before ]]; then unchanged; else new_active; fi
                signal=TERM
                [[ "$CASE" != kill-* ]] || signal=KILL
                kill "-$signal" "$worker"
                kill -TERM "$(< "$R/barrier-pid")"
                expect_failure wait "$worker"
                if [[ "$CASE" == *-before ]]; then unchanged; else new_active; fi
                live > "$R/interrupted-live"
                if [[ "$CASE" == *-after ]]; then
                    printf '%s\n' "$OLD" > "$R/answers"
                    printf '%s\n' "$OLD" > "$R/secondary"
                fi
                arm activation before
                bash "$FW" lockdown provider.test secondary.test > "$R/worker.log" 2>&1 &
                worker=$!
                wait_file "$R/reached"
                live > "$R/retry-live"
                cmp "$R/interrupted-live" "$R/retry-live"
                if [[ "$CASE" == *-before ]]; then unchanged; else new_active; fi
                : > "$R/release"
                wait "$worker"
                if [[ "$CASE" == *-before ]]; then new_active; else unchanged; fi
                stop_watch
                ;;
            state-committed|state-backend|state-layout|state-missing-backend|state-missing-layout|state-pending-committed)
                case "$CASE" in
                    state-committed) real_tables -X CLAUDE_LOCKDOWN; rm -- "$STATE/backend" "$STATE/layout" ;;
                    state-backend) printf 'invalid\n' > "$STATE/backend" ;;
                    state-layout) real_tables -D OUTPUT -p udp --dport 53 -j ACCEPT ;;
                    state-missing-backend) rm -- "$STATE/backend" ;;
                    state-missing-layout) rm -- "$STATE/layout" ;;
                    state-pending-committed) printf 'provider.test\n' > "$STATE/installing" ;;
                esac
                real_tables -S > "$R/before"
                guarded
                real_tables -S > "$R/after"
                cmp "$R/before" "$R/after"
                ;;
            smoke-positive|smoke-negative)
                new_answers
                if [ "$CASE" = smoke-positive ]; then : > "$R/smoke-positive-fail"; else : > "$R/smoke-negative-success"; fi
                expect_failure fw lockdown provider.test secondary.test
                new_active
                ;;
            *) die "unknown scenario: $CASE" ;;
        esac
        ;;
esac
