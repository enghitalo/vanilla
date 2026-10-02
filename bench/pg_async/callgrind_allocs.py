#!/usr/bin/env python3
"""callgrind_allocs.py — allocation calls per request from a callgrind dump.

Parses a raw callgrind.out (name-compressed or not), sums the calls made to
each allocator entry point by its immediate caller, and divides by the number
of requests the instrumented window served (docs/V_PERF_TOOLBOX.md,
"Profiling allocations"). Under -gc none every allocation is plain libc, so
the libc total is the number that must read 0 in steady state; the V-level
table names the code that asked for it. The instructions per request come
from the dump's total (the instrumented window only).

usage: callgrind_allocs.py <callgrind.out> <requests>
"""

import re
import sys
from collections import defaultdict

# libc's allocators: what -gc none V allocations bottom out in.
LIBC = {'malloc', 'calloc', 'realloc', 'posix_memalign', 'aligned_alloc', 'memalign', 'valloc'}
# V's builtin allocation entry points (vlib/builtin), -gc none flavours.
V_ALLOC = {
    '_v_malloc', 'malloc_noscan', 'malloc_uninit', 'malloc_uninit_noscan', 'vcalloc', 'vcalloc_noscan',
    'memdup', 'memdup_noscan', 'memdup_uninit', 'v_realloc', 'realloc_data', 'builtin___v_malloc',
    'builtin__malloc_noscan', 'builtin__malloc_uninit', 'builtin__vcalloc', 'builtin__vcalloc_noscan',
    'builtin__memdup', 'builtin__memdup_noscan', 'builtin__memdup_uninit', 'builtin__v_realloc',
    'builtin__realloc_data', 'builtin__malloc_uninit_noscan'
}

NAMED = re.compile(r'^(c?fn)=\((\d+)\)(?: (.*))?$')
PLAIN = re.compile(r'^(c?fn)=(.*)$')


def base(name):
    # callgrind marks recursion/cycles as name'2 and may append an object.
    return name.split("'")[0].strip()


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    path, requests = sys.argv[1], int(sys.argv[2])
    names = {}
    calls = defaultdict(int)  # (caller, callee) -> calls
    cur = None
    callee = None
    instructions = 0
    with open(path, errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if line.startswith('summary:') or line.startswith('totals:'):
                instructions = int(line.split()[1])
                continue
            m = NAMED.match(line)
            if m:
                kind, ident, name = m.groups()
                if name:
                    names[ident] = base(name)
                resolved = names.get(ident, ident)
                if kind == 'fn':
                    cur, callee = resolved, None
                else:
                    callee = resolved
                continue
            m = PLAIN.match(line)
            if m:
                kind, name = m.groups()
                if kind == 'fn':
                    cur, callee = base(name), None
                else:
                    callee = base(name)
                continue
            if line.startswith('calls=') and callee is not None:
                n = int(line[6:].split()[0])
                calls[(cur, callee)] += n
                callee = None
    libc_total = sum(n for (caller, c), n in calls.items() if c in LIBC and caller not in LIBC)
    per = requests if requests > 0 else 1
    print(f'requests in the instrumented window: {requests}')
    print(f'instructions: {instructions}  =  {instructions / per:.0f} per request')
    print(f'libc allocation calls: {libc_total}  =  {libc_total / per:.4f} per request')
    if libc_total == 0:
        return
    # Attribute each libc allocation call to the first real caller: through
    # PLT stubs and unnamed addresses (inlined allocators in a -prod build) and
    # V's allocator entry points, splitting a node's calls among its callers
    # in proportion to the calls each made into it (callgrind keeps one level
    # of context, so this is the usual inclusive estimate).
    callers = defaultdict(list)
    for (caller, c), n in calls.items():
        callers[c].append((caller, n))
    sites = defaultdict(float)

    def transparent(name):
        return name in LIBC or name in V_ALLOC or name.startswith('0x') or '@plt' in name or name == '???'

    def attribute(node, count, depth):
        into = callers.get(node, [])
        total = sum(n for _, n in into)
        if total == 0 or depth > 8:
            sites[node] += count
            return
        for caller, n in into:
            share = count * n / total
            if transparent(caller):
                attribute(caller, share, depth + 1)
            else:
                sites[caller] += share

    for (caller, c), n in calls.items():
        if c in LIBC and caller not in LIBC:
            if transparent(caller):
                attribute(caller, n, 0)
            else:
                sites[caller] += n
    print('allocation calls by first non-allocator caller (per request):')
    for site, n in sorted(sites.items(), key=lambda kv: -kv[1])[:25]:
        print(f'  {n / per:10.4f}  {n:12.0f}  {site}')


if __name__ == '__main__':
    main()
