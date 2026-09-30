module http2

fn st(tag int) &StreamState {
	return &StreamState{
		declared_len: i64(tag)
	}
}

fn test_stream_table_put_get_remove() {
	mut t := new_stream_table()
	for id := u32(1); id < 200; id += 2 {
		t.put(id, st(int(id)))
	}
	assert t.len == 100
	for id := u32(1); id < 200; id += 2 {
		s := t.get(id) or { panic('missing ${id}') }
		assert s.declared_len == i64(id)
	}
	assert !t.has(2)
	assert !t.has(0)
	for id := u32(1); id < 200; id += 4 {
		t.remove(id)
	}
	assert t.len == 50
	for id := u32(1); id < 200; id += 2 {
		assert t.has(id) == ((id - 1) % 4 != 0)
	}
}

fn test_stream_table_collisions_and_backward_shift() {
	mut t := new_stream_table()
	// ids 512 apart share a home slot (id >> 1 differs by 256): one probe run,
	// wrapping from the last slot to the first
	base := u32(2 * (stream_slots - 1) + 1) // home = last slot
	ids := [base, base + 512, base + 1024, base + 1536]
	for id in ids {
		t.put(id, st(int(id)))
	}
	assert t.len == 4
	// removing the head must pull the rest of the run back so they stay found
	t.remove(ids[0])
	t.remove(ids[2])
	assert !t.has(ids[0])
	assert !t.has(ids[2])
	for id in [ids[1], ids[3]] {
		s := t.get(id) or { panic('lost ${id} after backward shift') }
		assert s.declared_len == i64(id)
	}
	t.remove(ids[1])
	t.remove(ids[3])
	assert t.len == 0
	for i in 0 .. stream_slots {
		assert t.ids[i] == 0
	}
}

fn test_stream_table_sliding_window_like_a_connection() {
	// a live window of 100 ascending odd ids sliding over thousands of streams,
	// the shape a multiplexing client produces
	mut t := new_stream_table()
	mut live := []u32{}
	mut next := u32(1)
	for _ in 0 .. 5000 {
		if live.len == 100 {
			t.remove(live[0])
			live.delete(0)
		}
		t.put(next, st(int(next)))
		live << next
		next += 2
		assert t.len == live.len
	}
	for id in live {
		assert t.has(id)
	}
	mut ids := []u32{}
	t.ids_into(mut ids)
	ids.sort()
	assert ids == live
}
