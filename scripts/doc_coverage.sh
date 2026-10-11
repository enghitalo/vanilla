#!/usr/bin/env sh
# doc_coverage.sh — doc-comment coverage of the public API, per module
# (CHECKLIST #42).
#
# A top-level `pub fn`, `pub struct`, `pub enum`, `pub const`, `pub type`,
# `pub interface` or `pub union` counts as documented when the comment block
# directly above it (attributes such as `@[inline]` may sit in between) starts
# with `// <name>`, the form `v doc` renders and `v vet` expects. A comment
# that does not start with the name is reported as "loose". Methods count
# under their own name: `pub fn (mut s Server) run()` wants `// run ...`.
# Fields in a struct's `pub:` / `pub mut:` sections are counted apart: one is
# documented by a comment line above it or a trailing comment.
#
# Usage, from the repo root:
#   scripts/doc_coverage.sh                 # every module
#   scripts/doc_coverage.sh tls server      # these trees (sub-modules included)
#   scripts/doc_coverage.sh -v tls          # also list what is undocumented
#
# A module is one directory; `_test.v` files are skipped.

set -u

verbose=0
if [ "${1:-}" = "-v" ]; then
    verbose=1
    shift
fi
if [ $# -eq 0 ]; then
    set -- $(find . -name '*.v' ! -name '*_test.v' ! -path './examples/*' \
        ! -path './bench/*' ! -path './tests/*' ! -path './.claude/*' \
        ! -path './.git/*' -exec dirname {} \; | sed 's|^\./||' | cut -d/ -f1 | sort -u)
fi

files=$(for root in "$@"; do
    find "$root" -name '*.v' ! -name '*_test.v' | sort
done)
[ -n "$files" ] || { echo "no .v files under: $*" >&2; exit 1; }

# shellcheck disable=SC2086 # file names are split on purpose (no spaces in the tree)
awk -v verbose="$verbose" '
function report_missing(kind, name, why) {
    if (verbose) missing[dir] = missing[dir] sprintf("  %s:%d: %s %s (%s)\n", FILENAME, FNR, kind, name, why)
}
FNR == 1 {
    dir = FILENAME
    sub(/\/[^\/]*$/, "", dir)
    if (!(dir in seen)) { seen[dir] = 1; order[++ndirs] = dir }
    nprev = 0; in_struct = 0; pub_section = 0
}
{
    line = $0
    # Struct bodies: count pub fields, track the section we are in.
    if (in_struct) {
        if (line ~ /^}/) { in_struct = 0 }
        else if (line ~ /^[ \t]*pub( mut)?:[ \t]*$/) { pub_section = 1 }
        else if (line ~ /^[ \t]*(mut|__global)?:[ \t]*$/) { pub_section = 0 }
        else if (pub_section && line ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]+[^ \t\/]/ && line !~ /^[ \t]*\/\//) {
            fname = line; sub(/^[ \t]*/, "", fname); sub(/[ \t].*/, "", fname)
            fields[dir]++
            if (line ~ /\/\// || (nprev > 0 && prev[nprev] ~ /^[ \t]*\/\//)) fields_doc[dir]++
            else report_missing("field", fname, "no comment")
        }
    }
    else if (line ~ /^pub (fn|struct|enum|const|type|interface|union)[ \t(]/) {
        kind = line; sub(/^pub /, "", kind); sub(/[ \t(].*/, "", kind)
        rest = line; sub(/^pub [a-z]+[ \t]*/, "", rest)
        if (kind == "fn" && rest ~ /^\(/) {
            # method: skip the receiver
            sub(/^\([^)]*\)[ \t]*/, "", rest)
        }
        name = rest; sub(/[^A-Za-z0-9_.].*/, "", name)
        if (kind == "struct" && line ~ /{[ \t]*$/) { in_struct = 1; pub_section = 0 }
        decls[dir]++
        # Walk up over attributes to the comment block.
        i = nprev
        while (i > 0 && prev[i] ~ /^[ \t]*@\[/) i--
        if (i == 0 || prev[i] !~ /^[ \t]*\/\//) {
            report_missing(kind, name, "no comment")
        } else {
            while (i > 1 && prev[i - 1] ~ /^[ \t]*\/\//) i--
            # also allow attributes above the comment block
            first = prev[i]; sub(/^[ \t]*\/\/[ \t]?/, "", first)
            n = length(name)
            if (substr(first, 1, n) == name && (length(first) == n || substr(first, n + 1, 1) !~ /[A-Za-z0-9_]/)) {
                documented[dir]++
            } else {
                loose[dir]++
                report_missing(kind, name, "comment does not start with the name")
            }
        }
    }
    # keep a short window of previous lines
    if (nprev < 64) { prev[++nprev] = line }
    else { for (k = 1; k < 64; k++) prev[k] = prev[k + 1]; prev[64] = line }
}
END {
    printf "%-28s %6s %6s %6s %6s   %s\n", "module", "decls", "doc", "loose", "pct", "pub fields (doc/total)"
    for (d = 1; d <= ndirs; d++) {
        m = order[d]
        if (decls[m] == 0 && fields[m] == 0) continue
        pct = decls[m] ? 100 * documented[m] / decls[m] : 100
        printf "%-28s %6d %6d %6d %5.0f%%   %d/%d\n", m, decls[m], documented[m], loose[m], pct, fields_doc[m], fields[m]
        td += decls[m]; tdoc += documented[m]; tl += loose[m]; tf += fields[m]; tfd += fields_doc[m]
        if (verbose && missing[m] != "") printf "%s", missing[m]
    }
    printf "%-28s %6d %6d %6d %5.0f%%   %d/%d\n", "TOTAL", td, tdoc, tl, td ? 100 * tdoc / td : 100, tfd, tf
}' $files
