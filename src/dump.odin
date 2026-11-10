package inspecteur

// A dump file of a process's memory (Create dump file…, Ctrl+Shift+D, asked first): written on a thread of its own, as
// a large process takes seconds. The footer says where it went, or why none was written (nothing opens by itself: the
// file may be large and private). The system's side is dump_linux.odin (process_dump).

import "core:strings"
import "gt:ui"

// The longest name a dump's file takes from its process.
DUMP_NAME_MAX :: 64

Dump :: struct {
	worker:  ui.Worker,
	// what the window asks (under the worker's mutex)
	target:  Target,
	name:    [DUMP_NAME_MAX]u8,
	name_len: int,
	// what came of it (under the worker's mutex; owned)
	path, why: string,
	running: bool,   // the window's: a dump asked and not done
}

dump_init :: proc(d: ^Dump, app: ^App) { ui.worker_start(&d.worker, dump_job, d, app.main.win) }

dump_destroy :: proc(d: ^Dump) {
	ui.worker_stop(&d.worker)
	delete(d.path)
	delete(d.why)
}

// Writes a dump of the process `t` (named `name` in the footer) on the dump's thread.
dump_start :: proc(app: ^App, t: Target, name: string) {
	d := &app.dump
	if app.demo != nil { say(app, "The demo's processes are not the system's: no dump was written"); return }
	if d.running { say(app, "A dump is being written already"); return }
	p := find_proc(&app.sampler, t.pid, t.start)
	if p == nil { say(app, "%s has ended already", name); return }
	ui.worker_lock(&d.worker)
	d.target = t
	d.name_len = copy(d.name[:], p.name)
	ui.worker_unlock(&d.worker)
	d.running = true
	ui.worker_ask(&d.worker)
	say(app, "Writing a dump of %s…", name)
}

@(private = "file")
dump_job :: proc(w: ^ui.Worker) {
	d := (^Dump)(w.user)
	ui.worker_lock(w)
	t := d.target
	name := strings.clone(string(d.name[:d.name_len]), context.temp_allocator)
	ui.worker_unlock(w)
	path, why := process_dump(t.pid, t.start, name)
	ui.worker_lock(w)
	delete(d.path)
	delete(d.why)
	d.path, d.why = strings.clone(path), strings.clone(why)
	ui.worker_unlock(w)
	ui.worker_published(w)
}

// The window's turn: what the dump came to, said.
dump_take :: proc(app: ^App) {
	d := &app.dump
	if !ui.worker_take(&d.worker) { return }
	d.running = false
	ui.worker_lock(&d.worker)
	path, why := strings.clone(d.path, context.temp_allocator), strings.clone(d.why, context.temp_allocator)
	ui.worker_unlock(&d.worker)
	if why != "" { say(app, "No dump: %s", why); return }
	say(app, "Wrote the dump %s", path)
}
