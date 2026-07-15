module main

// Windows stub for the argon2 offload (the real pool lives in offload_nix.c.v).
// IOCP has no watch reactor, so .suspend would be dropped; make_state returns nil
// and handle()'s `$if !windows` guard keeps the synchronous verify path. The
// offload symbols (AuthState / try_offload / token_done) are referenced only
// inside that guard, so they need no Windows definition.
fn make_auth_state() voidptr {
	return unsafe { nil }
}
