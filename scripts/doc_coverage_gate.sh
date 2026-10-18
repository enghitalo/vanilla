#!/usr/bin/env sh
# doc_coverage_gate.sh — fail when a module whose public API was fully
# documented at a base commit no longer is (CHECKLIST #42, vanilla#360).
#
# Runs this tree's scripts/doc_coverage.sh on <base>'s .v files and on the
# working tree, and compares each module present in both. A module at 100%
# at the base (every declaration with a doc comment that starts with its
# name) must stay there, and so must its pub fields when they were all
# documented (a module with none counts: a new undocumented one fails).
# Modules below 100% at the base, and new or removed ones, are not checked.
#
# Usage, from the repo root:
#   scripts/doc_coverage_gate.sh origin/main
# CI (architecture.yml) runs it on every pull request against its base.

set -eu

base=${1:?usage: scripts/doc_coverage_gate.sh <base-commit>}
coverage="$(pwd)/scripts/doc_coverage.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

mkdir "$tmp/base"
git archive "$base" -- ':(glob)**/*.v' | tar -x -C "$tmp/base"
(cd "$tmp/base" && sh "$coverage") > "$tmp/base.txt"
sh "$coverage" > "$tmp/head.txt"

# Rows: module decls doc loose pct fields_doc/fields_total.
if awk '
NR == FNR {
    if ($1 != "module" && $1 != "TOTAL") { decls[$1] = $2; doc[$1] = $3; fields[$1] = $6 }
    next
}
$1 != "module" && $1 != "TOTAL" && ($1 in decls) && doc[$1] == decls[$1] {
    split(fields[$1], bf, "/")
    split($6, hf, "/")
    if ($3 < $2) {
        printf "%s: %d of %d declarations documented, all %d were at the base\n", $1, $3, $2, decls[$1]
        bad = 1
    }
    if (bf[1] == bf[2] && hf[1] < hf[2]) {
        if (bf[2] == 0) printf "%s: %d of %d pub fields documented; the base had none\n", $1, hf[1], hf[2]
        else printf "%s: %d of %d pub fields documented, all %d were at the base\n", $1, hf[1], hf[2], bf[2]
        bad = 1
    }
}
END { exit bad }' "$tmp/base.txt" "$tmp/head.txt" > "$tmp/regressed.txt"; then
    echo "doc coverage: every module at 100% at $base still is"
    exit 0
fi
cat "$tmp/regressed.txt"
echo
echo "What is missing (a comment must start with the name; see scripts/doc_coverage.sh):"
# shellcheck disable=SC2046 # module names have no spaces
sh "$coverage" -v $(cut -d: -f1 "$tmp/regressed.txt" | sort -u)
exit 1
