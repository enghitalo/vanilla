module main

import os
import log
import handler { new_app }

fn main() {
	mut l := log.Log{}
	l.set_output_stream(os.stdout())
	log.info('${@METHOD}  ${@MOD}.${@FILE_LINE}')

	new_app()
}
