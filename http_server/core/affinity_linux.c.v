module core

#include <sched.h>

fn C.sched_getaffinity(pid int, cpusetsize usize, mask &u64) int

// linux_affinity_cpu_count counts the CPUs this process is actually allowed to run
// on (its sched_getaffinity mask), so a taskset-pinned or cpuset-limited server
// spawns one worker per USABLE core instead of one per host core. Returns 0 on
// failure, signalling the caller (worker_count) to fall back to runtime.nr_cpus().
fn linux_affinity_cpu_count() int {
	mut mask := [16]u64{} // CPU_SETSIZE/64 words → up to 1024 CPUs
	if C.sched_getaffinity(0, usize(sizeof(mask)), &mask[0]) != 0 {
		return 0
	}
	mut n := 0
	for word in mask {
		mut w := word
		for w != 0 {
			w &= w - 1 // clear the lowest set bit (Kernighan popcount)
			n++
		}
	}
	return n
}
