#!/usr/bin/env sh
# migrate_imports.sh — rewrite pre-restructure vanilla imports to the new
# module tree (GitHub issue #122: http_server → server, http1_1 → http1,
# protocol-neutral modules hoisted to top level).
#
# Usage: scripts/migrate_imports.sh [dir]
#   dir — root of the consumer project to rewrite (default: .)
#
# The sed map is ordered longest-path-first so `http_server.core` rewrites
# before bare `http_server`. Both the external (`vanilla.`-prefixed) and the
# vendored (bare) import forms are handled. The V compiler verifies the
# result exhaustively: it builds or it doesn't.
#
# CAVEAT: after the rewrite, a local variable named `server` in a file that
# imports the `server` module is a compile error ("duplicate of a module
# name"). The script flags those files; rename the variable (e.g. to `srv`).

set -eu

dir=${1:-.}

find "$dir" -name '*.v' -not -path '*/.git/*' -print0 | xargs -0 -r perl -pi -e '
    # --- import lines, longest paths first ---------------------------------
    s/^(import\s+)vanilla\.http_server\.http1_1\./${1}vanilla.http1./;
    s/^(import\s+)vanilla\.http_server\.backend_epoll\b/${1}vanilla.server.backend_epoll/;
    s/^(import\s+)vanilla\.http_server\.(core|socket|epoll|tls|static_assets|testkit|io_uring|kqueue|iocp)\b/${1}vanilla.$2/;
    s/^(import\s+)vanilla\.http_server\b/${1}vanilla.server/;
    s/^(import\s+)http_server\.http1_1\./${1}http1./;
    s/^(import\s+)http_server\.backend_epoll\b/${1}server.backend_epoll/;
    s/^(import\s+)http_server\.(core|socket|epoll|tls|static_assets|testkit|io_uring|kqueue|iocp)\b/${1}$2/;
    s/^(import\s+)http_server\b/${1}server/;
    s/^(import\s+)http1_1\./${1}http1./;
    # --- qualified call sites (leaf names are unchanged, so only the bare
    #     module rename needs call-site rewrites: http_server.X -> server.X) --
    s/\bhttp_server\./server./g;
'

# Flag files where a local `server` identifier now shadows the module import.
echo "Rewrite done. Files that import \`server\` AND use a bare \`server\` identifier"
echo "(rename the variable, e.g. to \`srv\` — V forbids shadowing a module name):"
grep -rlE '^import (vanilla\.)?server( |\{|$)' --include='*.v' "$dir" 2>/dev/null | while IFS= read -r f; do
    if grep -qE '(^|[^._[:alnum:]])server([^_[:alnum:]]|$)' "$f" && \
       grep -E '(^|[^._[:alnum:]])server([^_[:alnum:]]|$)' "$f" | grep -vqE '^\s*(//|import |module )'; then
        if grep -qE '(mut )?server\s*:=|fn \[(mut )?server\]|\(mut server |\(server ' "$f"; then
            echo "  $f"
        fi
    fi
done
echo "Done. Compile with V to verify: the compiler catches anything the map missed."
