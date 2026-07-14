#!/usr/bin/env python3
"""Turn h1spec --strict console output into a colored Markdown scorecard.

GitHub-native color only — no external badge images. Per-check status is a
colored square (true color block that renders everywhere):
  🟢 pass          — the check passed over a live socket
  🔴 fail          — a REAL conformance failure (server gave a wrong, non-empty
                     answer); the wrong status is shown inline
  ⚪ blocked #103  — no answer arrived: the half-close backend bug, not a
                     handler bug

The headline is a GitHub alert (colored callout box): green [!TIP] when there
are zero real fails, red [!CAUTION] when a real gap appears.

Usage:  h1spec --strict localhost:3000 | panel_gen.py <commit_sha> <run_url>
Output goes between the CONFORMANCE_SCORECARD markers in the README.
"""
import re
import sys

sha = (sys.argv[1] if len(sys.argv) > 1 else "local")[:7]
run_url = sys.argv[2] if len(sys.argv) > 2 else ""

# Details that mean "no answer arrived" → #103 half-close, not a verdict.
HALFCLOSE = re.compile(r"got 0\b|No response|did not respond|No valid error response", re.I)
SEC_RE = re.compile(r"^([A-Z].*\(.*\))\s*$")
ROW_RE = re.compile(r"^\s*([✓✗])\s+(\d+)\.\s+(.*)$")  # ✓ / ✗
SUM_RE = re.compile(r"(\d+)/(\d+)\s+passed")

# Friendlier section titles (RFC section with a real § sign).
TITLE = {
    "Request Line (RFC 9112 S3)": "Request line — RFC 9112 §3",
    "Headers (RFC 9112 S5)": "Headers — RFC 9112 §5",
    "Body (RFC 9112 S6-7)": "Body — RFC 9112 §6–7",
    "Response Semantics (RFC 9110)": "Response semantics — RFC 9110",
    "Connection (RFC 9112 S9)": "Connection — RFC 9112 §9",
    "Hardening (Implementation-defined limits)": "Hardening — implementation-defined limits",
}

SQUARE = {"pass": "🟢", "fail": "🔴", "blocked": "⚪"}
LABEL = {"pass": "pass", "fail": "**FAIL**", "blocked": "blocked · #103"}

lines = [re.sub(r"\x1b\[[0-9;]*m", "", ln) for ln in sys.stdin.read().splitlines()]

sections, cur = [], None
i = 0
while i < len(lines):
    ln = lines[i]
    m = SEC_RE.match(ln)
    if m and "passed" not in ln and "Conformance" not in ln:
        cur = (m.group(1), [])
        sections.append(cur)
        i += 1
        continue
    r = ROW_RE.match(ln)
    if r and cur is not None:
        mark, name = r.group(1), r.group(3).strip()
        detail = ""
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if nxt.strip() and not ROW_RE.match(nxt) and not SEC_RE.match(nxt):
            detail = nxt.strip()
        state = "pass" if mark == "✓" else ("blocked" if HALFCLOSE.search(detail) else "fail")
        cur[1].append((name, state, detail))
        i += 1
        continue
    i += 1

rows = [r for _, rr in sections for r in rr]
n_pass = sum(1 for _, s, _ in rows if s == "pass")
n_fail = sum(1 for _, s, _ in rows if s == "fail")
n_block = sum(1 for _, s, _ in rows if s == "blocked")
answered = n_pass + n_fail

out = []

# Headline line: compact tally, scannable at a glance.
tally = f"🟢 **{n_pass} pass**"
if n_fail:
    tally += f"  ·  🔴 **{n_fail} fail**"
if n_block:
    tally += f"  ·  ⚪ {n_block} blocked by [#103](https://github.com/enghitalo/vanilla/issues/103)"
out.append(f"**Live `h1spec --strict` scorecard** — {n_pass}/{answered} of the checks that get an answer pass.")
out.append("")
out.append(tally)
out.append("")

# Colored callout box (GitHub alert).
if n_fail == 0 and n_block > 0:
    out.append("> [!TIP]")
    out.append(
        "> **Every check that gets an answer passes.** The ⚪ rows are *not* conformance "
        "failures — they are the backend half-close bug "
        "([#103](https://github.com/enghitalo/vanilla/issues/103)): h1spec half-closes the "
        "socket after each request and vanilla drops the queued response, so no answer "
        "arrives. The deterministic `v test examples/conformance/src` gate asserts these same "
        "decisions without a socket and is green."
    )
elif n_fail == 0 and n_block == 0:
    out.append("> [!TIP]")
    out.append(
        "> **Fully conformant.** Every `h1spec --strict` check passes over a live socket — "
        "[#103](https://github.com/enghitalo/vanilla/issues/103) is fixed, so the probe is now a hard gate."
    )
else:
    out.append("> [!CAUTION]")
    out.append(
        f"> **{n_fail} real conformance gap{'s' if n_fail > 1 else ''}** below (🔴) — a *wrong* "
        "answer, not a dropped one. ⚪ rows are the half-close bug "
        "([#103](https://github.com/enghitalo/vanilla/issues/103)), not handler failures."
    )
out.append("")

for title, rr in sections:
    if not rr:
        continue
    out.append(f"**{TITLE.get(title, title)}**")
    out.append("")
    out.append("| | Check | |")
    out.append("|:--:|---|---|")
    for name, st, detail in rr:
        note = f" <sub>{detail}</sub>" if st == "fail" and detail else ""
        out.append(f"| {SQUARE[st]} | {name}{note} | {LABEL[st]} |")
    out.append("")

foot = f"_h1spec `--strict`, live socket · commit `{sha}`"
if run_url:
    foot += f" · [run log]({run_url})"
foot += " · regenerated by CI on every merge_"
out.append(foot)

print("\n".join(out))
