module core

// Pure resolution rules every backend relies on (Limits.idle_ms,
// Limits.sweep_interval_ms) — one definition, so the backends cannot drift.

fn test_idle_ms_resolution() {
	// Nothing set: nothing armed.
	assert Limits{}.idle_ms() == 0
	// 0 inherits read_timeout_ms (Go IdleTimeout rule).
	assert Limits{
		read_timeout_ms: 5000
	}.idle_ms() == 5000
	// An explicit positive value wins over the inherited one.
	assert Limits{
		read_timeout_ms: 5000
		idle_timeout_ms: 60_000
	}.idle_ms() == 60_000
	assert Limits{
		idle_timeout_ms: 300
	}.idle_ms() == 300
	// Negative opts out, even with a read timeout set.
	assert Limits{
		read_timeout_ms: 5000
		idle_timeout_ms: -1
	}.idle_ms() == 0
	// A negative read timeout is "off" like every other `> 0` check.
	assert Limits{
		read_timeout_ms: -1
	}.idle_ms() == 0
}

fn test_sweep_interval_ms() {
	assert Limits{}.sweep_interval_ms() == 0
	assert Limits{
		read_timeout_ms: 5000
		idle_timeout_ms: -1
	}.sweep_interval_ms() == 250
	// A quarter of the shortest active timeout...
	assert Limits{
		read_timeout_ms: 400
	}.sweep_interval_ms() == 100
	assert Limits{
		read_timeout_ms:  5000
		write_timeout_ms: 800
	}.sweep_interval_ms() == 200
	assert Limits{
		read_timeout_ms:  5000
		idle_timeout_ms:  600
		write_timeout_ms: 0
	}.sweep_interval_ms() == 150
	// ...clamped to [25, 250] ms.
	assert Limits{
		read_timeout_ms: 40
	}.sweep_interval_ms() == 25
	assert Limits{
		write_timeout_ms: 60_000
	}.sweep_interval_ms() == 250
	// The idle budget counts only when it resolves on.
	assert Limits{
		idle_timeout_ms:  -1
		write_timeout_ms: 0
	}.sweep_interval_ms() == 0
}
