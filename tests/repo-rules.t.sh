#!/bin/bash
# repo-rules.t.sh - rules over the toolkit's own host-side shell, found the hard way.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
sandbox

# date +%<digits>N: uutils coreutils 0.10.0 (Ubuntu 26.04's /usr/bin/date) formats
# a truncated %N from the nanosecond integer without zero-padding it to nine digits,
# so in the first tenth of every second %3N prints 10x or 100x the real value
# (ns=012765933 -> "140") and consecutive timestamps run backwards. This put a
# ts-done beacon 0.4 s before the collect beacon written earlier and made
# tests/shell.t.sh fail in one run of ten (tests/README.md, "Host notes").
# The rule: the repo's shell takes %N and cuts it (${t::-6}) or uses $msec / Python.
subsecond_date_hits() {   # <dir>... -> the offending lines (code, not comments; not this file, which is the rule)
    {
        command grep -rnE 'date .*%[0-9]+N' "$@" --include='*.sh' --include='*.t.sh' 2>/dev/null
        for f in "$1"/*; do   # bin/ scripts have no extension
            [[ -f "$f" ]] && head -c 64 "$f" | command grep -q '^#!/bin/bash' && command grep -nHE 'date .*%[0-9]+N' "$f"
        done
    } | command grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' | command grep -v '/repo-rules\.t\.sh:'
    return 0
}
hits="$(subsecond_date_hits "$REPO/bin" "$REPO/tests" "$REPO/spikes")"
if [[ -z "$hits" ]]; then pass "no date +%<digits>N in bin/, tests/ or spikes/ shell (uutils %3N is wrong in the first 100 ms of every second)"
else fail "no date +%<digits>N in bin/, tests/ or spikes/ shell" "$hits"; fi

# control: the rule sees a planted one
mkdir -p "$T/planted/bin" "$T/planted/tests"
printf '#!/bin/bash\nt=$(date +%%s.%%3N)\n' > "$T/planted/bin/x"
printf 'stamp=$(date +%%3N)\n' > "$T/planted/tests/y.t.sh"
hits="$(subsecond_date_hits "$T/planted/bin" "$T/planted/tests")"
if [[ "$(wc -l <<<"$hits")" == 2 ]] && grep -q 'bin/x:2' <<<"$hits" && grep -q 'y.t.sh:1' <<<"$hits"; then control "the rule catches a planted %3N in a bin/ script and in a test (2 hits)"
else fail "CONTROL: the rule catches a planted %3N" "hits: [$hits]"; fi

# a note, not a verdict: what this host's date does (so the row is reread when the host changes)
n=0; bad=0
for _ in $(seq 400); do ab=$(date +%N_%3N); n=$((n+1)); [[ "${ab:0:3}" == "${ab#*_}" ]] || bad=$((bad+1)); done   # one reading, both formats
if (( bad == 0 )); then pass "this host's date +%3N agrees with the first 3 digits of %N ($n samples; the rule still stands)"
else pass "this host's date +%3N disagrees with %N in $bad of $n samples ($(date --version | head -1)): the rule is live here"; fi
finish
