module admin

import veb
import structs {Context}

// pub struct Context {
// 	veb.Context
// }

pub struct Admin {
	veb.Middleware[Context]
}
