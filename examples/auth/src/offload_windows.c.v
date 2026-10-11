module main

// Windows stub for the argon2 offload (the real pool lives in offload_nix.c.v).
// IOCP has no watch reactor, so .suspend would be dropped: the worker's
// AuthState gets no pool (nil), and handle()'s `$if !windows` guard keeps the
// synchronous verify path. The offload functions (try_offload / token_done) are
// referenced only inside that guard, so they need no Windows definition.
@[heap]
struct HashPool {}

fn make_auth_state() voidptr {
	return voidptr(new_auth_state(unsafe { nil }))
}
