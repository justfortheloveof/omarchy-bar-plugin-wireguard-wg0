#!/usr/bin/env bash
# _seq.sh - shared sequencing and side-effect logging for the tests/stub
# binaries. Sourced by `ip`, `wg`, `wg-quick` so all three sequence identically.
#
# Environment:
#   WG_STUB_SEQ_FILE   optional; one directive per line, applied per invocation.
#                      A stub pops the next directive tagged for its own tool
#                      name (the prefix stripped) under flock on
#                      "<file>.lock"; with no directive left for the tool the
#                      ambient WG_STUB* variable governs. Syntax:
#                        <tool>: <state> [delay=<ms>] [ignore-term]
#                      e.g. "wg-quick: ok delay=1500 ignore-term", "ip: up"
#   WG_STUB_DELAY_MS   ambient sleep-before-output, when no directive sets a delay
#   WG_STUB_IGNORE_TERM 1 : `trap '' TERM`, so the stub survives SIGTERM
#   WG_STUB_LOG        optional; appends "<tool>\t<state>\t<delay_ms>\t<argv...>"
#                      so the runner can assert counts and ordering offline
#
# `seq_start <tool> <argv...>` leaves `seq_state` / `seq_delay` / `seq_ignore`
# set, sleeps, installs the TERM trap, logs, and returns 0 when it consumed a
# directive, 1 when it fell back to ambient state.
set -euo pipefail

seq_start() {
    seq_tool=$1
    shift
    seq_state=""
    seq_delay=0
    seq_ignore=0
    seq_directive=""

    if [[ "${WG_STUB_SEQ_FILE:-}" != "" ]]; then
        seq_directive=$(seq_pop "$seq_tool") || true
        seq_parse "$seq_directive"
    fi

    if [[ "${WG_STUB_IGNORE_TERM:-0}" == "1" || "$seq_ignore" == "1" ]]; then
        trap '' TERM
    fi

    # Ambient delay is the baseline; a directive's delay= overrides it.
    if [[ "$seq_delay" == "0" || "$seq_delay" == "" ]]; then
        seq_delay=${WG_STUB_DELAY_MS:-0}
    fi

    if [[ -n "${WG_STUB_LOG:-}" ]]; then
        printf '%s\t%s\t%s\t%s\n' \
            "$seq_tool" "${seq_state:---}" "${seq_delay:-0}" "$*" >>"$WG_STUB_LOG"
    fi

    if [[ "${seq_delay:-0}" -gt 0 ]]; then
        sleep "$(awk "BEGIN{printf \"%.3f\", $seq_delay/1000}")"
    fi

    [[ "$seq_directive" != "" ]]
}

# Pop the next directive tagged for <tool> (or an un-prefixed one) and echo it
# (tool prefix stripped) on stdout; run under flock so concurrent stubs never
# double-pop. The remaining lines are rewritten in place.
seq_pop() {
    local tool=$1
    local lock="${WG_STUB_SEQ_FILE}.lock"
    local picked

    picked=$(
        {
            flock 9
            if [[ ! -s "$WG_STUB_SEQ_FILE" ]]; then
                exit 0
            fi
            local new="${WG_STUB_SEQ_FILE}.new.$$"
            : >"$new"
            local found=""
            local line tag
            while IFS= read -r line || [[ -n "$line" ]]; do
                line=${line%%$'\r'}
                [[ "$line" != "" ]] || continue
                if [[ "${line:0:1}" == "#" ]]; then
                    printf '%s\n' "$line" >>"$new"
                    continue
                fi
                if [[ "$found" != "" ]]; then
                    printf '%s\n' "$line" >>"$new"
                    continue
                fi
                if [[ "$line" =~ ^[a-zA-Z-]+: ]]; then
                    tag=${line%%:*}
                    if [[ "$tag" == "$tool" ]]; then
                        found=${line#*:}
                        # consume our directive: do not re-emit it
                    else
                        printf '%s\n' "$line" >>"$new"
                    fi
                else
                    # un-prefixed directive: first pop wins
                    found=$line
                fi
            done <"$WG_STUB_SEQ_FILE"
            mv "$new" "$WG_STUB_SEQ_FILE"
            printf '%s\n' "$found"
        } 9>"$lock"
    )

    printf '%s' "$picked"
}

# Parse a directive body into seq_state / seq_delay / seq_ignore.
seq_parse() {
    local raw=$1
    local state="" delay=0 ignore=0
    if [[ -n "$raw" ]]; then
        for word in $raw; do
            case "$word" in
            delay=*)
                delay=${word#delay=}
                ;;
            ignore-term)
                ignore=1
                ;;
            *)
                state=$word
                ;;
            esac
        done
    fi
    seq_state=$state
    seq_delay=$delay
    seq_ignore=$ignore
}
