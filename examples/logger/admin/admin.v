module admin

import veb
import log
import structs {Context}

@['/router'; get]
fn (app &Admin) index(mut ctx Context) veb.Result {
	log.info('${@METHOD}  ${@MOD}.${@FILE_LINE}')
	return ctx.json('admin success')
}
