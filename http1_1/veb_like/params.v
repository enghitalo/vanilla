module veb_like

import http1_1.request_parser { Slice }

// Params holds the :name / *name values of the matched route as offsets into
// the request buffer. It lives on the router's stack frame for one request.
//
// The eight value slots are plain fields, not a `[8]Slice`: V moves a local
// struct that contains a fixed-size array to the heap (memdup) when a function
// it is passed to passes it on (every handler calls p.get), which would cost
// one allocation per request (V 0.5.2 5516000; one call deep it stays local).
// A struct of plain fields stays on the stack; the slots are reached by index
// through the first one's address (same type, adjacent, no padding between).
pub struct Params {
mut:
	n     int
	route &Route = unsafe { nil } // the matched route: its param names, in path order
	base  &u8    = unsafe { nil } // the request buffer
	v0    Slice
	v1    Slice
	v2    Slice
	v3    Slice
	v4    Slice
	v5    Slice
	v6    Slice
	v7    Slice
}

@[inline]
fn (mut p Params) push(s Slice) {
	unsafe {
		mut slots := &Slice(&p.v0)
		slots[p.n] = s
	}
	p.n++
}

// len is the number of params the matched route captured.
@[inline]
pub fn (p &Params) len() int {
	return p.n
}

// get returns the value of the param named `name` (`id` for `:id`, `path` for
// `*path`), or '' when the route has none. The string is a zero-copy view of
// the request bytes, raw (not percent-decoded): valid until the handler
// returns, so `.clone()` what must outlive the request.
pub fn (p &Params) get(name string) string {
	for i in 0 .. p.n {
		if same(p.route.names[i], name) {
			return p.at(i)
		}
	}
	return ''
}

// at returns the i-th param value in path order ('' when out of range), as
// the same zero-copy view as get.
pub fn (p &Params) at(i int) string {
	s := p.slice_at(i)
	if s.len <= 0 {
		return ''
	}
	return unsafe { tos(p.base + s.start, s.len) }
}

// slice returns the offsets of the param named `name` in the request buffer
// (Slice{} when absent), for code that works on offsets.
pub fn (p &Params) slice(name string) Slice {
	for i in 0 .. p.n {
		if same(p.route.names[i], name) {
			return p.slice_at(i)
		}
	}
	return Slice{}
}

@[inline]
fn (p &Params) slice_at(i int) Slice {
	if i < 0 || i >= p.n {
		return Slice{}
	}
	return unsafe { (&Slice(&p.v0))[i] }
}

// same compares two short strings (param names, path segments) inline: for a
// handful of bytes a loop beats a call into libc's memcmp.
@[direct_array_access; inline]
fn same(a string, b string) bool {
	if a.len != b.len {
		return false
	}
	for i in 0 .. a.len {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
