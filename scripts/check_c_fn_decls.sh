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
#
# Run from the repo root. Exits non-zero on any violation.

set -u

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
'
