#!/usr/bin/env sh
# check_c_fn_decls.sh — grep-enforced: `fn C.` declarations of one C function
# agree on its return type (#383).
#
# V registers `fn C.` declarations program-wide and types every call to the
# function, in every module, by one of its declarations, picked by parse order
# (vlang/v#30915). With two return types, code that relies on its own
# declaration's type builds or fails depending on what else the program
# imports: http1_1/client's `p - base` on its `&u8` memchr broke as soon as a
# `voidptr` declaration won.
#
#   - A C function declared in several files returns the same type in all.
#   - memchr and memmem, when declared, return voidptr, as vlib's builtin
#     declares them for every module.
#   - No `usize`, `isize` or `uint` in any .v file (#385): V master deprecates the
#     first two (vlang/v#31113) and -prod makes that an error, while the V before
#     it has no `uint` at all; u64 and i64 hold on both.
#   - No declaration of the libc functions vlib or a consumer also declares with a
#     size type (send, recv, sendto, read, write, pread, sendfile, memset, memcpy,
#     memmove, memchr): vanilla calls them as vanilla_* (core/libc_shim.h), so its
#     declarations never meet theirs, whichever V (#385).
#
# Run from the repo root. Exits non-zero on any violation.

set -u

status=0
sizes=$(grep -rnwE --include='*.v' --exclude-dir=.git --exclude-dir=.claude 'usize|isize|uint' . || true)
if [ -n "$sizes" ]; then
    printf 'usize, isize or uint (use u64 and i64, #385):\n%s\n\n' "$sizes"
    status=1
fi
libc=$(grep -rnE --include='*.v' --exclude-dir=.git --exclude-dir=.claude \
    '^[[:space:]]*(pub[[:space:]]+)?fn[[:space:]]+C\.(send|recv|sendto|read|write|pread|sendfile|memset|memcpy|memmove|memchr)[[:space:]]*\(' . || true)
if [ -n "$libc" ]; then
    printf 'a libc function declared under its own name (use C.vanilla_*, core/libc_shim.h, #385):\n%s\n\n' "$libc"
    status=1
fi

grep -rnE --include='*.v' --exclude-dir=.git --exclude-dir=.claude \
    '^[[:space:]]*(pub[[:space:]]+)?fn[[:space:]]+C\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(' . |
    awk '
{
    # grep -n output: path:line:text
    p = index($0, ":"); path = substr($0, 1, p - 1); rest = substr($0, p + 1)
    p = index(rest, ":"); where = path ":" substr(rest, 1, p - 1)
    t = substr(rest, p + 1)
    t = substr(t, index(t, "C.") + 2)
    o = index(t, "(")
    name = substr(t, 1, o - 1)
    sub(/[ \t]+$/, "", name)
    # The return type follows the parenthesis that closes the parameters.
    depth = 0
    for (i = o; i <= length(t); i++) {
        c = substr(t, i, 1)
        if (c == "(") {
            depth++
        } else if (c == ")") {
            depth--
            if (depth == 0) break
        }
    }
    ret = substr(t, i + 1)
    sub(/\/\/.*/, "", ret)
    gsub(/[ \t]+/, " ", ret)
    sub(/^ /, "", ret)
    sub(/ $/, "", ret)
    if (ret == "") ret = "nothing"
    if (!((name, ret) in seen)) {
        seen[name, ret] = 1
        kinds[name]++
    }
    decls[name] = decls[name] "\n    " where ": returns " ret
    if ((name == "memchr" || name == "memmem") && ret != "voidptr") {
        builtin = builtin "\n    " where ": C." name " returns " ret
    }
}
END {
    for (name in kinds) {
        if (kinds[name] > 1) {
            printf "C.%s is declared with different return types:%s\n\n", name, decls[name]
            fail = 1
        }
    }
    if (builtin != "") {
        printf "C.memchr and C.memmem must return voidptr, as vlib builtin declares them:%s\n\n", builtin
        fail = 1
    }
    if (fail) {
        print "V types every call to a C function by one of its declarations (#383,"
        print "vlang/v#30915): give them the same return type and cast at the call."
        exit 1
    }
    print "C declarations check OK."
}
' || status=1
exit "$status"
