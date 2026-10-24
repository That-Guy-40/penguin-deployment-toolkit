#!/bin/bash
# native-tests.sh - tools-src/pdt-sha256.c compiled natively on Linux and checked
# against FIPS 180-4 vectors, coreutils sha256sum, and the sidecars bin/stage-image
# wrote with Python's hashlib (three independent implementations). Also every exit
# code, with inputs built to provoke each one. Run from the repo root:
#   spikes/2026-10-24-sha256-and-dism/native-tests.sh
set -u
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
fail=0
say() { echo "$*"; }
chk() {  # chk <label> <want> <got>
    if [[ "$2" == "$3" ]]; then say "PASS  $1"; else say "FAIL  $1: want '$2' got '$3'"; fail=$((fail+1)); fi
}

say "\$ gcc -std=c99 -pedantic -O2 -Wall -Wextra -Wconversion -Wshadow -Werror -o pdt-sha256 tools-src/pdt-sha256.c"
gcc -std=c99 -pedantic -O2 -Wall -Wextra -Wconversion -Wshadow -Werror -o "$W/pdt-sha256" tools-src/pdt-sha256.c; rc=$?
chk "native compile, warnings are errors" 0 "$rc"
[[ $rc -eq 0 ]] || exit 1
P="$W/pdt-sha256"
cd "$W" || exit 1

say "--- FIPS 180-4 vectors"
printf '' > v0; printf 'abc' > v1
printf 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq' > v2
head -c 1000000 /dev/zero | tr '\0' a > v3
chk "empty"         e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 "$("$P" v0 | cut -d' ' -f1)"
chk "abc"           ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad "$("$P" v1 | cut -d' ' -f1)"
chk "448-bit"       248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1 "$("$P" v2 | cut -d' ' -f1)"
chk "a x 1,000,000" cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0 "$("$P" v3 | cut -d' ' -f1)"

say "--- random files at block and buffer boundaries, vs sha256sum"
n=0; bad=0
for sz in 1 2 3 54 55 56 57 63 64 65 118 119 120 121 127 128 129 1000 1048575 1048576 1048577 2097153 5000001; do
    head -c "$sz" /dev/urandom > "r$sz"
    a="$("$P" "r$sz" | cut -d' ' -f1)"; b="$(sha256sum "r$sz" | cut -d' ' -f1)"
    n=$((n+1)); [[ "$a" == "$b" ]] || { say "      differs at $sz bytes"; bad=$((bad+1)); }
done
chk "$n sizes agree with sha256sum" 0 "$bad"

say "--- a file over 4 GiB (the length field's high word), vs sha256sum"
head -c 4400000000 /dev/zero > big
a="$("$P" big | cut -d' ' -f1)"; b="$(sha256sum big | cut -d' ' -f1)"
chk "4,400,000,000 zero bytes" "$b" "$a"
rm -f big

say "--- the sidecar rule, exit codes 0 / 1 / 4"
printf 'abc' > t1; H="$(sha256sum t1 | cut -d' ' -f1)"; HU="$(echo "$H" | tr a-f A-F)"
printf '{\n  "file": "t1",\n  "size": 3,\n  "sha256": "%s",\n  "provenance": {"apps_sha256": "0000000000000000000000000000000000000000000000000000000000000000"}\n}\n' "$H" > sc-good.json
printf '{"size": 3, "sha256":"%s"}' "$HU" > sc-upper.json
printf '{"size": 3, "sha256": "%s"}' "${H:0:63}0" > sc-wrong.json
printf '{"size": 3, "sha256": "%s0"}' "$H" > sc-65.json
printf '{"size": 3, "sha256": "%s"' "${H:0:63}" > sc-63.json
printf '{"size": 3, "sha256": 5}' > sc-num.json
printf '{"size": 3}' > sc-none.json
printf '{"apps_sha256": "%s"}' "$H" > sc-apps.json
printf '{"sha256"' > sc-eof.json
{ printf '{"a":"'; printf '\0'; printf '", "sha256": "%s"}' "$H"; } > sc-nul.json
head -c 1048577 /dev/zero | tr '\0' ' ' > sc-huge.json
for case in "good 0" "upper 0" "wrong 1" "65 4" "63 4" "num 4" "none 4" "apps 4" "eof 4" "nul 0" "huge 4"; do
    set -- $case
    "$P" --check "sc-$1.json" t1 > out.txt 2> err.txt; rc=$?
    chk "sidecar $1 -> exit $2   ($(tail -1 out.txt)$(cat err.txt))" "$2" "$rc"
done

say "--- usage and unreadable files, exit codes 2 / 3"
"$P" >/dev/null 2>&1;                         chk "no arguments -> 2" 2 $?
"$P" --check only >/dev/null 2>&1;            chk "--check with one argument -> 2" 2 $?
"$P" --nope >/dev/null 2>&1;                  chk "unknown option -> 2" 2 $?
"$P" nosuchfile t1 >out.txt 2>/dev/null;      chk "a missing file among others -> 3, the others still printed" "3 $H" "$? $(cut -d' ' -f1 out.txt)"
"$P" --check nosuch.json t1 >/dev/null 2>&1;  chk "missing sidecar -> 3" 3 $?
"$P" --check sc-good.json nosuch >/dev/null 2>&1; chk "missing file -> 3" 3 $?
mkdir d; "$P" d >/dev/null 2>&1;              chk "a directory -> 3" 3 $?

cd - >/dev/null || exit 1
say "--- the served images, vs their sidecars (bin/stage-image, Python hashlib)"
for img in http/images/*.wim; do
    [[ "$img" == *.winre.wim ]] && continue
    sc="${img%.wim}.json"
    out="$("$P" --check "$sc" "$img" 2>&1)"; rc=$?
    chk "$(basename "$img") matches $(basename "$sc") ($(stat -c%s "$img") bytes)" "0 match" "$rc $(tail -1 <<<"$out")"
done
say "--- base.wim, vs sha256sum (a third implementation)"
a="$("$P" http/images/base.wim | cut -d' ' -f1)"; b="$(sha256sum http/images/base.wim | cut -d' ' -f1)"
chk "base.wim: pdt-sha256 == sha256sum" "$b" "$a"

say
if [[ $fail -eq 0 ]]; then say "all checks passed"; else say "$fail check(s) FAILED"; fi
exit $(( fail > 0 ))
