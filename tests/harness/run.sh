#!/usr/bin/env bash
# Stub-driven QML harness for Service.qml. Runs each scenario in its own
# `quickshell -p` process against tests/stub/, then checks the stub call log
# (counts, notifications) that the QML side cannot see. Nothing real is run.
#
# Usage: run.sh [scenario...]   (default: all)
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
stubdir="$root/tests/stub"
harnessdir="$root/tests/harness"

scratch=$(mktemp -d /tmp/wg-harness.XXXXXX)
trap 'rm -rf "$scratch"' EXIT

# Flat scratch dir so the harness's sibling imports resolve.
for f in Service.qml CommandProcess.qml Model.js; do
    ln -s "$root/$f" "$scratch/$f"
done
cp "$harnessdir/harness.qml" "$scratch/harness.qml"

# A quickshell that hangs (e.g. while loading) fails its scenario instead of
# blocking the run. Scenarios cap themselves at ~14 s.
run_timeout=30

failed=0
passes=0
only=" $* "

# run <scenario> <seq-file> [extra env as VAR=val ...]
run() {
    local scn=$1 seqfile=$2
    shift 2
    if [[ "$only" != "  " && "$only" != *" $scn "* ]]; then
        return 0
    fi
    local log="$scratch/$scn.log"
    local sweep="$scratch/$scn.seq"
    cp "$seqfile" "$sweep"
    : >"$log"
    local cmd=(env)
    cmd+=(PATH="$stubdir:$PATH")
    cmd+=(QML_IMPORT_PATH=/usr/share/omarchy/shell QT_QPA_PLATFORM=offscreen)
    cmd+=(HARNESS_SCENARIO="$scn" HARNESS_BIN_DIR="$stubdir/")
    cmd+=(WG_STUB_SEQ_FILE="$sweep" WG_STUB_LOG="$log")
    cmd+=(WG_STUB_PEER=one WG_STUB_ACTION=ok WG_STUB=down)
    for kv in "$@"; do
        cmd+=("$kv")
    done
    cmd+=(timeout "$run_timeout" quickshell -p "$scratch/harness.qml")

    local out pass_line fail_line
    out=$(printf '%s\n' "$("${cmd[@]}" 2>&1 || true)" | sed -e 's/\x1b\[[0-9;]*m//g')
    pass_line=$(printf '%s\n' "$out" | grep -m1 "PASS $scn:" || true)
    fail_line=$(printf '%s\n' "$out" | grep -m1 "FAIL $scn:" || true)

    if ! expect_log "$scn"; then
        failed=$((failed + 1))
        printf 'FAIL %s: runner log expectation not met (ip=%s wg=%s wg-quick=%s notify=%s)\n' \
            "$scn" "$(count_log "$scn" ip)" "$(count_log "$scn" wg)" \
            "$(count_log "$scn" wg-quick)" "$(count_log "$scn" omarchy-notification-send)"
        printf '%s\n' "$out" | sed 's/^/    /' | tail -8
        return 1
    fi
    if [[ -n "$pass_line" ]]; then
        passes=$((passes + 1))
        printf 'PASS %s: %s\n' "$scn" "${pass_line##*PASS $scn: }"
        return 0
    fi
    if [[ -n "$fail_line" ]]; then
        failed=$((failed + 1))
        printf '%s\n' "$fail_line"
        return 1
    fi
    failed=$((failed + 1))
    printf 'FAIL %s: quickshell produced no verdict\n' "$scn"
    printf '%s\n' "$out" | sed 's/^/    /' | tail -12
    return 1
}

# count_log <scn> <tool>: number of logged calls to <tool>.
count_log() {
    local scn=$1 tool=$2
    awk -F '\t' "\$1 == \"$tool\" { n++ } END { print n+0 }" "$scratch/$scn.log"
}

# expect_log <scn>: per-scenario call counts. nf counts notifications.
expect_log() {
    local scn=$1
    local ip wg wgq su nf
    ip=$(count_log "$scn" ip)
    wg=$(count_log "$scn" wg)
    wgq=$(count_log "$scn" wg-quick)
    su=$(count_log "$scn" sudo)
    nf=$(count_log "$scn" omarchy-notification-send)
    # Every wg/wg-quick call went through sudo, with a stub path. >= because a
    # child killed at scenario exit may log its sudo line but not its own.
    [[ $su -ge $((wg + wgq)) ]] || return 1
    if [[ $su -gt 0 ]] && grep '^sudo' "$scratch/$scn.log" | grep -v "$stubdir" | grep -q .; then
        return 1
    fi
    case "$scn" in
    s01) [[ $ip -eq 3 && $wgq -eq 1 && $nf -eq 0 ]] ;;
    s02) [[ $ip -eq 3 && $wgq -eq 1 && $nf -eq 1 ]] ;;
    s03) [[ $ip -eq 2 && $wgq -eq 1 && $nf -eq 1 ]] ;;
    s04) [[ $ip -eq 2 && $wg -ge 1 && $wgq -eq 1 && $nf -eq 0 ]] ;;
    s05) [[ $ip -eq 2 && $wg -ge 1 && $wgq -eq 1 && $nf -eq 0 ]] ;;
    s06) [[ $ip -ge 3 && $wg -ge 3 && $nf -eq 1 ]] ;;
    s07) [[ $ip -eq 2 && $wg -ge 1 && $nf -eq 1 ]] ;;
    s08) [[ $ip -eq 1 && $wgq -eq 0 && $nf -eq 1 ]] ;;
    s09) [[ $ip -eq 3 && $wgq -eq 2 && $nf -eq 1 ]] ;;
    s10) [[ $ip -eq 3 && $wgq -eq 2 && $nf -eq 1 ]] ;;
    s11) [[ $ip -eq 4 && $wgq -eq 2 && $nf -eq 2 ]] ;;
    s12) [[ $ip -ge 3 && $wg -ge 7 && $nf -eq 1 ]] ;;
    s13) [[ $ip -ge 5 && $wg -ge 3 && $wgq -eq 2 && $nf -eq 1 ]] ;;
    s14) [[ $ip -eq 2 && $wgq -eq 0 && $nf -eq 1 ]] ;;
    # wg >= 7: the boot chain, then at least one query of the recovery chain.
    s15) [[ $ip -eq 5 && $wg -ge 7 && $wgq -eq 1 && $nf -eq 2 ]] ;;
    s16) [[ $ip -eq 3 && $wgq -eq 2 && $nf -eq 1 ]] ;;
    s17) [[ $ip -eq 3 && $wgq -eq 1 && $nf -eq 1 ]] ;;
    # Exactly 3 polls: a surplus one would hit the ambient down and fake a drop.
    # nf==2: the ip error and the drop, on separate dedupe keys.
    s18) [[ $ip -eq 3 && $wg -ge 1 && $wgq -eq 0 && $nf -eq 2 ]] ;;
    # The one notification is the status timeout; the late down is ours, not a drop.
    s19) [[ $ip -eq 3 && $wgq -eq 1 && $nf -eq 1 ]] ;;
    # The refresh during the boot poll runs afterwards: exactly 2 polls.
    s20) [[ $ip -eq 2 && $wg -ge 1 && $wgq -eq 0 && $nf -eq 0 ]] ;;
    # error, error (deduped), down (re-arms), error: 4 polls, 2 notifications.
    s21) [[ $ip -eq 4 && $wg -eq 0 && $wgq -eq 0 && $nf -eq 2 ]] ;;
    s22) [[ $ip -eq 2 && $wg -ge 6 && $wgq -eq 0 && $nf -eq 0 ]] ;;
    s23) [[ $ip -eq 2 && $wg -ge 6 && $wgq -eq 0 && $nf -eq 1 ]] ;;
    # Three polls, each with a full stale chain, two toasts: one per episode, the
    # second after the tightened threshold re-armed it.
    s24) [[ $ip -eq 3 && $wg -eq 18 && $wgq -eq 0 && $nf -eq 2 ]] ;;
    s25) [[ $ip -eq 1 && $wg -eq 6 && $wgq -eq 0 && $nf -eq 1 ]] ;;
    s26) [[ $ip -eq 3 && $wg -eq 12 && $wgq -eq 2 && $nf -eq 2 ]] ;;
    s27) [[ $ip -eq 2 && $wg -eq 0 && $wgq -eq 0 && $nf -eq 0 ]] ;;
    # Back-to-back 2.5 s polls would fit 4 in 8 s; skipped ticks leave at most 3,
    # plus one the harness may catch starting as it exits.
    s28) [[ $ip -ge 2 && $ip -le 4 && $wg -eq 0 && $nf -eq 0 ]] ;;
    # Boot down, verify down (error kept), then the manual up clears it.
    s29) [[ $ip -eq 3 && $wgq -eq 1 && $nf -eq 1 ]] ;;
    # Two polls, two full chains; the toast only after the simulated wait.
    s30) [[ $ip -eq 2 && $wg -eq 12 && $wgq -eq 0 && $nf -eq 1 ]] ;;
    # Drop, error, down (re-arms), error: the same ip error notifies twice.
    s31) [[ $ip -eq 5 && $wgq -eq 0 && $nf -eq 3 ]] ;;
    *) return 1 ;;
    esac || return 1
    if [[ $scn == s15 ]]; then
        expect_drop_toasts "$scn" || return 1
    fi
    if [[ $scn == s24 || $scn == s25 || $scn == s26 || $scn == s30 ]]; then
        expect_handshake_toasts "$scn" || return 1
    fi
    return 0
}

# expect_drop_toasts <scn>: every notification is the outside-drop toast,
# with its exact urgency, glyph, body and click action.
# Log fields: tool, app-name, urgency, glyph, headline, body, exec.
expect_drop_toasts() {
    local scn=$1
    local log="$scratch/$scn.log"
    local want_body="The wg0 tunnel was brought down unexpectedly! Click to bring it back up."
    local want_exec="/usr/share/omarchy/bin/omarchy-shell io.github.justfortheloveof.wireguard-wg0 bringUp"
    awk -F '\t' -v b="$want_body" -v x="$want_exec" '
    BEGIN { bad = 0 }
    $1 == "omarchy-notification-send" {
      if ($2 != "WireGuard wg0") { print "app-name: " $2 > "/dev/stderr"; bad = 1 }
      if ($3 != "critical") { print "urgency: " $3 > "/dev/stderr"; bad = 1 }
      if ($4 != "󰴴") { print "glyph: " $4 > "/dev/stderr"; bad = 1 }
      if ($5 != "WireGuard wg0") { print "headline: " $5 > "/dev/stderr"; bad = 1 }
      if ($6 != b) { print "body: " $6 > "/dev/stderr"; bad = 1 }
      if ($7 != x) { print "exec: " $7 > "/dev/stderr"; bad = 1 }
    }
    END { exit bad }
  ' "$log"
}

# expect_handshake_toasts <scn>: every notification is the stale-handshake
# toast for the stub peer: normal urgency, no click action.
expect_handshake_toasts() {
    local scn=$1
    local want_body="Peer ZZZZZZ…ZZZZZ= has had no handshake for over 2m 15s"
    awk -F '\t' -v b="$want_body" '
    BEGIN { bad = 0 }
    $1 == "omarchy-notification-send" {
      if ($3 != "normal") { print "urgency: " $3 > "/dev/stderr"; bad = 1 }
      if ($6 != b) { print "body: " $6 > "/dev/stderr"; bad = 1 }
      if ($7 != "-") { print "exec: " $7 > "/dev/stderr"; bad = 1 }
    }
    END { exit bad }
  ' "$scratch/$scn.log"
}

# Vehicle probe: env plumbing and stub wiring work before any scenario runs.
veh_out=$(env PATH="$stubdir:$PATH" QML_IMPORT_PATH=/usr/share/omarchy/shell \
    QT_QPA_PLATFORM=offscreen HARNESS_SCENARIO=vehicle HARNESS_BIN_DIR="$stubdir/" \
    HARNESS_PROBE=ok timeout "$run_timeout" quickshell -p "$scratch/harness.qml" 2>&1) || true
veh_out=$(printf '%s\n' "$veh_out" | sed -e 's/\x1b\[[0-9;]*m//g')
if ! printf '%s\n' "$veh_out" | grep -q "PASS vehicle:"; then
    echo "FAIL vehicle: harness vehicle check" >&2
    printf '%s\n' "$veh_out" | sed 's/^/    /' | tail -8
    exit 1
fi
passes=$((passes + 1))

# Scenario scripts: per-call stub behaviour, consumed in order per tool
# (see tests/stub/_seq.sh).
S() { printf '%s\n' "$@"; }
REP() {
    local n=$1 line=$2 i
    for ((i = 0; i < n; i++)); do printf '%s\n' "$line"; done
}

seq_s01="$scratch/seq_s01"
{
    S "ip: up" "ip: up" "ip: down"
    S "wg-quick: ok delay=1500"
} >"$seq_s01"

seq_s02="$scratch/seq_s02"
{
    # The failed down leaves the tunnel up, so the verify says up.
    S "ip: up" "ip: up" "ip: up"
    S "wg-quick: fail delay=1500"
} >"$seq_s02"

seq_s03="$scratch/seq_s03"
{
    # Delayed verify, so the timeout is observable before the down clears it.
    S "ip: up" "ip: down delay=600"
    S "wg-quick: hang"
} >"$seq_s03"

seq_s04="$scratch/seq_s04"
{
    # Delayed verify: without the generation bump, chain steps would land while
    # still "up" and repopulate peers.
    S "ip: up" "ip: down delay=1200"
    REP 6 "wg: one delay=300"
    S "wg-quick: ok delay=500"
} >"$seq_s04"

seq_s05="$scratch/seq_s05"
{
    S "ip: up" "ip: down"
    REP 6 "wg: one delay=300"
    S "wg-quick: ok"
} >"$seq_s05"

seq_s06="$scratch/seq_s06"
{
    # A fourth confirm keeps peerError visible longer than one 100 ms tick.
    S "ip: up" "ip: up" "ip: up" "ip: up"
} >"$seq_s06"

seq_s07="$scratch/seq_s07"
{
    S "ip: up" "ip: down"
} >"$seq_s07"

seq_s08="$scratch/seq_s08"
{
    S "ip: error"
} >"$seq_s08"

seq_s09="$scratch/seq_s09"
{
    S "ip: up" "ip: up" "ip: down"
    S "wg-quick: hang ignore-term"
    S "wg-quick: ok"
} >"$seq_s09"

seq_s10="$scratch/seq_s10"
{
    S "ip: up" "ip: down" "ip: up"
    S "wg-quick: hang ignore-term"
    S "wg-quick: ok delay=2500"
} >"$seq_s10"

seq_s11="$scratch/seq_s11"
{
    S "ip: up" "ip: error" "ip: up" "ip: down"
    S "wg-quick: fail" "wg-quick: ok"
} >"$seq_s11"

seq_s12="$scratch/seq_s12"
{
    S "ip: up" "ip: up" "ip: up" "ip: up"
    REP 6 "wg: one"
    S "wg: fail"
} >"$seq_s12"

seq_s13="$scratch/seq_s13"
{
    S "ip: up delay=600" # boot
    S "wg: fail delay=600"
    S "ip: up delay=600" # confirm: peerError, notify #1
    S "wg: fail delay=600"
    S "ip: down" # our down: box cleared, dedupe key kept
    S "wg: fail delay=600"
    S "ip: up delay=600" # our up
    S "wg: fail delay=600"
    S "ip: up delay=600" # confirm: same peerError, not re-notified
    S "wg: fail delay=600"
    S "ip: up delay=600" # spares for the hold phase
    S "wg: fail delay=600"
    S "ip: up delay=600"
    S "wg-quick: ok delay=300" # down
    S "wg-quick: ok delay=300" # up
} >"$seq_s13"

seq_s14="$scratch/seq_s14"
{
    S "ip: up" "ip: up-down"
    REP 6 "wg: one delay=300"
} >"$seq_s14"

seq_s15="$scratch/seq_s15"
{
    S "ip: up"       # boot
    S "ip: down"     # outside drop
    S "ip: down"     # refresh, still down
    S "ip: up"       # recovery verified
    S "ip: down"     # second outside drop
    S "wg-quick: ok" # recovery toggle
} >"$seq_s15"

seq_s16="$scratch/seq_s16"
{
    S "ip: up"                     # boot
    S "wg-quick: hang ignore-term" # run 1: needs SIGKILL
    S "ip: up"                     # run 1 verify
    S "wg-quick: hang"             # run 2: must hit its own watchdog
    S "ip: up"                     # run 2 verify
} >"$seq_s16"

seq_s17="$scratch/seq_s17"
{
    S "ip: up"       # boot
    S "wg-quick: ok" # our down succeeds, arming _expectDown
    S "ip: up"       # verify says up: clears the arm
    S "ip: down"     # later outside drop
} >"$seq_s17"

seq_s18="$scratch/seq_s18"
{
    S "ip: up"    # boot
    S "ip: error" # up-memory must survive this
    S "ip: down"  # outside drop
} >"$seq_s18"

seq_s19="$scratch/seq_s19"
{
    S "ip: up"            # boot
    S "wg-quick: ok"      # our down, arming _expectDown
    S "ip: up delay=5000" # verify outlives the 4 s watchdog
    S "ip: down"          # our down, late
} >"$seq_s19"

seq_s20="$scratch/seq_s20"
{
    S "ip: up delay=1200" # boot poll, still in flight for the refresh
    S "ip: up"            # the queued poll
} >"$seq_s20"

seq_s21="$scratch/seq_s21"
{
    # The recovery is a down (never seen up, so no drop) to avoid a peer chain.
    S "ip: error" "ip: error" "ip: down" "ip: error"
} >"$seq_s21"

seq_s22="$scratch/seq_s22"
{
    S "ip: up" "ip: down"
} >"$seq_s22"
seq_s23="$seq_s22"

seq_s26="$scratch/seq_s26"
{
    S "ip: up"       # boot, stale chain
    S "wg-quick: ok" # our down
    S "ip: down"     # verify
    S "wg-quick: ok" # our up
    S "ip: up"       # verify, stale chain again
} >"$seq_s26"

seq_s29="$scratch/seq_s29"
{
    S "ip: down"       # boot
    S "wg-quick: fail" # our up fails
    S "ip: down"       # verify: still down, the error stands
    S "ip: up"         # brought up by hand
} >"$seq_s29"

seq_s31="$scratch/seq_s31"
{
    S "ip: up"    # boot
    S "ip: down"  # outside drop: latched
    S "ip: error" # ip fails
    S "ip: down"  # readable again, still latched
    S "ip: error" # the same failure: notifies again
} >"$seq_s31"

# Shorter action watchdogs for the timeout scenarios. s10 needs room for
# run 1's late exit to land while run 2 is still running.
ACTS=HARNESS_ACTION_MS=2500
ACTS10=HARNESS_ACTION_MS=4000

# Keep going after a failing scenario.
set +e
run s01 "$seq_s01"
run s02 "$seq_s02"
run s03 "$seq_s03" "$ACTS"
run s04 "$seq_s04"
run s05 "$seq_s05"
run s06 "$seq_s06" WG_STUB_PEER=fail WG_STUB=up
run s07 "$seq_s07" WG_STUB_PEER=fail
run s08 "$seq_s08"
run s09 "$seq_s09" "$ACTS"
run s10 "$seq_s10" "$ACTS10"
run s11 "$seq_s11"
run s12 "$seq_s12" WG_STUB_PEER=fail WG_STUB=up
run s13 "$seq_s13" WG_STUB_PEER=fail
run s14 "$seq_s14"
run s15 "$seq_s15"
run s16 "$seq_s16" "$ACTS"
run s17 "$seq_s17"
run s18 "$seq_s18"
run s19 "$seq_s19"
run s20 "$seq_s20"
run s21 "$seq_s21"
run s22 "$seq_s22" HARNESS_PREFS='{"notifyExternalDrop":false}'
run s23 "$seq_s23"
run s24 /dev/null WG_STUB=up WG_STUB_PEER=stale
run s25 /dev/null WG_STUB=up WG_STUB_PEER=stale HARNESS_PREFS='{"handshakeError":false}'
run s26 "$seq_s26" WG_STUB_PEER=stale
run s27 /dev/null HARNESS_POLL_MS=0
run s28 /dev/null HARNESS_POLL_MS=1000 WG_STUB_DELAY_MS=2500
run s29 "$seq_s29"
run s30 /dev/null WG_STUB=up WG_STUB_PEER=never
run s31 "$seq_s31"
set -e

printf 'harness: %d passed, %d failed\n' "$passes" "$failed"
[[ $failed -eq 0 ]]
