#!/bin/bash
# aggregate.sh - one table from every <dir>/result.txt of this spike.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
printf '%-34s %-9s %-7s %-7s %s\n' "experiment" "reboots" "fine" "hung" "conditions"
tf=0; th=0
for r in */result.txt; do
    d="${r%/result.txt}"
    read -r vm fine hung n rest < "$r"
    if [[ "$d" == *control* ]]; then
        printf '%-34s %-9s %-7s %-7s %s\n' "$d" "$n" "$fine" "$hung" "CONTROL (not counted): the detector forced to fire on a healthy VM"
        continue
    fi
    printf '%-34s %-9s %-7s %-7s %s\n' "$d" "$n" "$fine" "$hung" "$vm: $rest"
    tf=$((tf+fine)); th=$((th+hung))
done
printf '%-34s %-9s %-7s %-7s\n' "TOTAL" "$((tf+th))" "$tf" "$th"
