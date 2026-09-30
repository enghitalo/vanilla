module http2

// StreamTable maps a connection's open stream ids to their state without
// allocating: a fixed open-addressing table (linear probing, backward-shift
// deletion, so no tombstones) sized once per connection. It replaces a
// map[u32]&StreamState, whose delete reallocates its dense array every few
// removals and whose keys() builds a fresh array on each walk, allocations
// that -gc none never frees (one insert + one delete per request).
//
// ServerConn never holds more than max_concurrent_streams entries (new
// streams past it are refused), so the table stays at most half full and a
// probe always meets an empty slot. Client stream ids are odd and ascending,
// so id >> 1 spreads the live window over consecutive slots.
const stream_slots = 256 // power of two, >= 2 * max_concurrent_streams

const stream_slot_mask = stream_slots - 1

struct StreamTable {
mut:
	ids  []u32 // 0 = empty (stream 0 is the connection, never a stream)
	vals []&StreamState
	len  int
}

fn new_stream_table() StreamTable {
	return StreamTable{
		ids:  []u32{len: stream_slots}
		vals: []&StreamState{len: stream_slots, init: unsafe { nil }}
	}
}

@[inline]
fn stream_home(id u32) int {
	return int(id >> 1) & stream_slot_mask
}

// find returns the slot holding `id`, or -1.
@[direct_array_access]
fn (t &StreamTable) find(id u32) int {
	if id == 0 {
		return -1
	}
	mut i := stream_home(id)
	for _ in 0 .. stream_slots {
		k := t.ids[i]
		if k == id {
			return i
		}
		if k == 0 {
			return -1
		}
		i = (i + 1) & stream_slot_mask
	}
	return -1
}

fn (t &StreamTable) get(id u32) ?&StreamState {
	i := t.find(id)
	if i < 0 {
		return none
	}
	return t.vals[i]
}

@[inline]
fn (t &StreamTable) has(id u32) bool {
	return t.find(id) >= 0
}

// put inserts or replaces id's state. The table cannot fill (see above), but
// a full probe is still bounded.
@[direct_array_access]
fn (mut t StreamTable) put(id u32, s &StreamState) {
	mut i := stream_home(id)
	for _ in 0 .. stream_slots {
		k := t.ids[i]
		if k == id {
			t.vals[i] = s
			return
		}
		if k == 0 {
			t.ids[i] = id
			t.vals[i] = s
			t.len++
			return
		}
		i = (i + 1) & stream_slot_mask
	}
}

// remove deletes id, then shifts later members of its probe run back into the
// hole so every remaining entry stays reachable from its home slot.
@[direct_array_access]
fn (mut t StreamTable) remove(id u32) {
	mut hole := t.find(id)
	if hole < 0 {
		return
	}
	mut j := hole
	for {
		j = (j + 1) & stream_slot_mask
		k := t.ids[j]
		if k == 0 {
			break
		}
		home := stream_home(k)
		// k may move into the hole unless its home lies cyclically in (hole, j]
		stays := if hole <= j { home > hole && home <= j } else { home > hole || home <= j }
		if !stays {
			t.ids[hole] = k
			t.vals[hole] = t.vals[j]
			hole = j
		}
	}
	t.ids[hole] = 0
	t.vals[hole] = unsafe { nil }
	t.len--
}

// ids_into refills `out` (a caller-retained buffer) with the live ids, for
// walks whose body may remove entries.
@[direct_array_access]
fn (t &StreamTable) ids_into(mut out []u32) {
	out.clear()
	if t.len == 0 {
		return
	}
	for i in 0 .. stream_slots {
		if t.ids[i] != 0 {
			out << t.ids[i]
		}
	}
}
