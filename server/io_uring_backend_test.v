// vtest build: linux
module server

// Unit test for the io_uring multishot-accept kernel gate. It stays in-module
// (unlike the backend's socket tests) because iou_release_supports_multishot
// is module-internal and the test needs no sockets at all.
//
// The end-to-end socket tests that used to live here (keep-alive 200 → 404
// routing, 4-pipelined-requests-in-one-write) moved to
// tests/io_uring_backend_test.v, on vtest.

// Guards the multishot-accept gate: the previous code keyed off a non-existent
// params.features bit (1 << 19), which is never set, so multishot was silently
// disabled on every kernel. Detection now keys off the kernel release.
fn test_iou_release_supports_multishot() {
	$if !linux {
		return
	}
	$if linux {
		// >= 5.19 → supported
		assert iou_release_supports_multishot('5.19.0-generic')
		assert iou_release_supports_multishot('6.8.0-41-generic')
		assert iou_release_supports_multishot('6.0.0')
		assert iou_release_supports_multishot('10.2.1-custom')
		// < 5.19 → single-shot fallback
		assert !iou_release_supports_multishot('5.18.0-generic')
		assert !iou_release_supports_multishot('5.4.0-200-generic')
		assert !iou_release_supports_multishot('4.19.255')
		// Malformed / unparseable → safe default (no multishot)
		assert !iou_release_supports_multishot('garbage')
		assert !iou_release_supports_multishot('6')
		assert !iou_release_supports_multishot('')
	}
}

// The ring-size cap shares a locked-memory budget evenly: the largest ladder
// size whose bound, times the worker count, fits; the smallest size when
// nothing fits.
fn test_iou_ring_entries_for_shares_the_memlock_budget() {
	$if linux {
		mib := u64(1024 * 1024)
		page := u64(4096)
		assert iou_ring_entries_for(8 * mib, 4, page) == 16384 // 4 x 2 MiB
		assert iou_ring_entries_for(8 * mib, 5, page) == 8192
		assert iou_ring_entries_for(8 * mib, 16, page) == 4096 // 16 x 512 KiB
		assert iou_ring_entries_for(8 * mib, 17, page) == 2048
		assert iou_ring_entries_for(8 * mib, 64, page) == 1024
		assert iou_ring_entries_for(8 * mib, 0, page) == 16384 // read as one worker
		assert iou_ring_entries_for(64 * 1024, 16, page) == 256 // nothing fits: the smallest
		assert iou_ring_entries_for(u64(1) << 40, 256, page) == 16384
		for workers in [1, 2, 3, 7, 16, 33, 100] {
			entries := iou_ring_entries_for(8 * mib, workers, page)
			if entries > 256 {
				assert iou_ring_lock_bytes(entries, page) * u64(workers) <= 8 * mib
			}
		}
	}
}

// With 64 KiB pages a small ring costs whole pages: 256 entries take two of
// them (128 KiB), not 256 x 128 B.
fn test_iou_ring_lock_bytes_counts_whole_pages() {
	$if linux {
		assert iou_ring_lock_bytes(256, 4096) == 32 * 1024
		assert iou_ring_lock_bytes(16384, 4096) == 2 * 1024 * 1024
		assert iou_ring_lock_bytes(256, 65536) == 128 * 1024
		assert iou_ring_lock_bytes(512, 65536) == 128 * 1024
		assert iou_ring_lock_bytes(2048, 65536) == 256 * 1024
		// 64 workers in 4 MiB: 512 entries with 4 KiB pages, the floor with 64 KiB.
		assert iou_ring_entries_for(4 * 1024 * 1024, 64, 4096) == 512
		assert iou_ring_entries_for(4 * 1024 * 1024, 64, 65536) == 256
	}
}

// Rings count against RLIMIT_MEMLOCK up to 5.11 and again from 6.14; 5.12 to
// 6.13 charge the memory cgroup instead.
fn test_iou_release_charges_rings() {
	$if linux {
		assert iou_release_charges_rings('4.19.255')
		assert iou_release_charges_rings('5.11.22-generic')
		assert !iou_release_charges_rings('5.12.0')
		assert !iou_release_charges_rings('5.15.0-91-generic')
		assert !iou_release_charges_rings('6.8.0-41-generic')
		assert !iou_release_charges_rings('6.13.12')
		assert iou_release_charges_rings('6.14.0')
		assert iou_release_charges_rings('7.1.13-2-MANJARO')
		assert !iou_release_charges_rings('garbage')
		assert !iou_release_charges_rings('6')
		assert !iou_release_charges_rings('')
	}
}

// CAP_IPC_LOCK (CapEff bit 14) exempts rings only in the initial user
// namespace: an identity uid_map.
fn test_iou_has_ipc_lock() {
	$if linux {
		init_ns := '         0          0 4294967295\n'
		userns := '         0       1000          1\n'
		all_caps := 'Name:\tvanilla\nCapInh:\t0000000000000000\nCapEff:\t000001ffffffffff\nCapBnd:\t000001ffffffffff\n'
		docker_root := 'CapEff:\t00000000a80425fb\n' // Docker's default set: no CAP_IPC_LOCK
		user := 'CapEff:\t0000000000000000\n'
		ipc_lock_only := 'CapEff:\t0000000000004000\n'
		assert iou_has_ipc_lock(all_caps, init_ns)
		assert iou_has_ipc_lock(ipc_lock_only, init_ns)
		assert !iou_has_ipc_lock(all_caps, userns) // unshare -r: caps in the namespace only
		assert !iou_has_ipc_lock(docker_root, init_ns)
		assert !iou_has_ipc_lock(user, init_ns)
		assert !iou_has_ipc_lock('', init_ns)
		assert !iou_has_ipc_lock(all_caps, '')
	}
}
