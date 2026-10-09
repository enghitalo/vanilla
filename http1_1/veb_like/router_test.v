module veb_like

// The router's own contract, independent of any one app: what new() accepts
// and rejects, and how a path picks its route. Each App type below declares
// just the routes a case needs.
import core
import http1_1.request_parser { HttpRequest }

fn get(raw_target string) string {
	return 'GET ${raw_target} HTTP/1.1\r\nHost: x\r\n\r\n'
}

fn run[T](r &Router[T], raw string) string {
	mut out := []u8{}
	mut el := core.EventLoop{}
	r.handle(raw.bytes(), mut out, -1, unsafe { nil }, mut el)
	return out.bytestr()
}

// echo appends the handler's name and its params as the body of a 200, so a
// test sees which route answered and what it captured.
fn echo(name string, p &Params, mut out []u8) core.Step {
	mut body := name
	for i in 0 .. p.len() {
		body += ' ${p.route.names[i]}=${p.at(i)}'
	}
	out << 'HTTP/1.1 200 OK\r\nContent-Length: ${body.len}\r\n\r\n${body}'.bytes()
	return .done
}

fn body(resp string) string {
	return resp.all_after('\r\n\r\n')
}

// ── priority and backtracking ────────────────────────────────────────────────

struct PriorityApp {}

@['GET /u/me']
fn (a &PriorityApp) me(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return echo('me', p, mut out)
}

@['GET /u/:id']
fn (a &PriorityApp) user(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return echo('user', p, mut out)
}

@['GET /u/*rest']
fn (a &PriorityApp) rest(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return echo('rest', p, mut out)
}

@['GET /a/b/c']
fn (a &PriorityApp) abc(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return echo('abc', p, mut out)
}

@['GET /a/:x/d']
fn (a &PriorityApp) axd(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return echo('axd', p, mut out)
}

@['GET /']
fn (a &PriorityApp) root(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return echo('root', p, mut out)
}

fn test_static_beats_param_beats_catch_all() {
	r := new[PriorityApp](&PriorityApp{})!
	assert body(run(r, get('/u/me'))) == 'me'
	assert body(run(r, get('/u/42'))) == 'user id=42'
	assert body(run(r, get('/u/42/x'))) == 'rest rest=42/x'
	assert body(run(r, get('/u/'))) == 'rest rest=' // empty segment: not a :id
}

fn test_dead_end_backtracks_into_the_param() {
	r := new[PriorityApp](&PriorityApp{})!
	assert body(run(r, get('/a/b/c'))) == 'abc'
	// /a/b/d: the static `b` branch dead-ends at `d`, so `:x` takes `b`
	assert body(run(r, get('/a/b/d'))) == 'axd x=b'
	assert run(r, get('/a/b/e')).starts_with('HTTP/1.1 404')
}

fn test_root_route() {
	r := new[PriorityApp](&PriorityApp{})!
	assert body(run(r, get('/'))) == 'root'
	assert body(run(r, get('/?q=1'))) == 'root'
}

// ── params: names belong to routes ───────────────────────────────────────────

struct NamesApp {}

@['GET /p/:id']
fn (a &NamesApp) by_id(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return echo('by_id', p, mut out)
}

@['GET /p/:owner/files/*path']
fn (a &NamesApp) files(_ HttpRequest, p &Params, mut out []u8) core.Step {
	assert p.get('owner') == p.at(0)
	assert p.get('path') == p.at(1)
	assert p.get('id') == '' // not this route's name
	assert p.slice('owner').len == p.at(0).len
	return echo('files', p, mut out)
}

fn test_param_names_are_per_route() {
	r := new[NamesApp](&NamesApp{})!
	assert body(run(r, get('/p/7'))) == 'by_id id=7'
	assert body(run(r, get('/p/ann/files/a/b.txt'))) == 'files owner=ann path=a/b.txt'
}

// ── non-route attributes are ignored; both handler shapes dispatch ───────────

struct ShapesApp {}

@['GET /short']
@[inline]
fn (a &ShapesApp) short(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return echo('short', p, mut out)
}

@['POST /long/:n']
fn (a &ShapesApp) long(_ HttpRequest, p &Params, mut out []u8, client_fd int, _ voidptr, mut _event_loop core.EventLoop) core.Step {
	out << 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n'.bytes()
	return if client_fd == 99 { core.Step.close } else { core.Step.done }
}

// not a handler: it returns something else, so the router never sees it
fn (a &ShapesApp) helper() int {
	return 1
}

// not a handler either: it returns core.Step but has no attribute, so it can
// take any parameters (a shared response helper, here)
fn (a &ShapesApp) teapot(mut out []u8) core.Step {
	out << "HTTP/1.1 418 I'm a teapot\r\nContent-Length: 0\r\n\r\n".bytes()
	return .done
}

fn test_both_shapes_and_extra_attributes() {
	r := new[ShapesApp](&ShapesApp{})!
	assert body(run(r, get('/short'))) == 'short'
	mut out := []u8{}
	mut el := core.EventLoop{}
	raw := 'POST /long/1 HTTP/1.1\r\nHost: x\r\n\r\n'.bytes()
	step := r.handle(raw, mut out, 99, unsafe { nil }, mut el)
	assert step == .close // client_fd reached the long handler
	assert ShapesApp{}.helper() == 1
	mut tea := []u8{}
	assert ShapesApp{}.teapot(mut tea) == .done
}

fn test_custom_not_found() {
	mut r := new[ShapesApp](&ShapesApp{})!
	r.not_found = 'HTTP/1.1 404 Not Found\r\nContent-Length: 4\r\n\r\nnope'
	assert body(run(r, get('/missing'))) == 'nope'
}

// ── what new() rejects ───────────────────────────────────────────────────────

struct DuplicateApp {}

@['GET /x/:id']
fn (a &DuplicateApp) one(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return .done
}

@['GET /x/:key']
fn (a &DuplicateApp) two(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return .done
}

struct StarNotLastApp {}

@['GET /f/*path/x']
fn (a &StarNotLastApp) f(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return .done
}

struct NamelessApp {}

@['GET /f/:']
fn (a &NamelessApp) f(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return .done
}

struct NoSlashApp {}

@['GET users']
fn (a &NoSlashApp) f(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return .done
}

struct TwiceApp {}

@['GET /f/:id/:id']
fn (a &TwiceApp) f(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return .done
}

struct TooManyApp {}

@['GET /:a/:b/:c/:d/:e/:f/:g/:h/:i']
fn (a &TooManyApp) f(_ HttpRequest, p &Params, mut out []u8) core.Step {
	return .done
}

fn test_startup_rejects_bad_routes() {
	if _ := new[DuplicateApp](&DuplicateApp{}) {
		assert false, 'duplicate route accepted'
	} else {
		assert err.msg().contains('already handled by one')
	}
	if _ := new[StarNotLastApp](&StarNotLastApp{}) {
		assert false, '*path in the middle accepted'
	} else {
		assert err.msg().contains('must be the last segment')
	}
	if _ := new[NamelessApp](&NamelessApp{}) {
		assert false, 'nameless param accepted'
	} else {
		assert err.msg().contains('nameless')
	}
	if _ := new[NoSlashApp](&NoSlashApp{}) {
		assert false, 'pattern without / accepted'
	} else {
		assert err.msg().contains('must be `METHOD /path`')
	}
	if _ := new[TwiceApp](&TwiceApp{}) {
		assert false, 'repeated param name accepted'
	} else {
		assert err.msg().contains('twice')
	}
	if _ := new[TooManyApp](&TooManyApp{}) {
		assert false, '9 params accepted'
	} else {
		assert err.msg().contains('the limit is 8')
	}
}

fn test_method_slots() {
	for i, name in method_names {
		assert method_slot(name.str, name.len) == i
	}
	assert method_slot(c'GETX', 4) == -1
	assert method_slot(c'get', 3) == -1
	assert method_slot(c'PROPFIND', 8) == -1
}
