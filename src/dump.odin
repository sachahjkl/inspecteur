package inspecteur

// A dump file of a process's memory (Create dump file…, Ctrl+Shift+D, asked first): written by a task of the toolkit's
// chores, as a large process takes seconds. The footer says where it went, or why none was written (nothing opens by
// itself: the file may be large and private). The system's side is dump_linux.odin (process_dump).

import "core:strings"
import "gt:ui"

Dump :: struct {
	running: bool,   // a dump asked and not done
}

// What a dump is asked for, and what came of it (owned).
@(private = "file")
Dump_Task :: struct {
	target:    Target,
	name:      string,   // the process's
	shown:     string,   // what the footer calls it
	path, why: string,
}

// Writes a dump of the process `t` (named `name` in the footer) on the chores.
dump_start :: proc(app: ^App, t: Target, name: string) {
	d := &app.dump
	if app.demo != nil { say(app, "The demo's processes are not the system's: no dump was written"); return }
	if d.running { say(app, "A dump is being written already"); return }
	p := find_proc(&app.sampler, t.pid, t.start)
	if p == nil { say(app, "%s has ended already", name); return }
	job := new(Dump_Task)
	job^ = {target = t, name = strings.clone(p.name), shown = strings.clone(name)}
	d.running = true
	ui.task(&app.main.state, dump_work, dump_done, job, dump_lost)
	say(app, "Writing a dump of %s…", name)
}

@(private = "file")
dump_work :: proc(data: rawptr) {
	j := (^Dump_Task)(data)
	path, why := process_dump(j.target.pid, j.target.start, j.name)
	j.path, j.why = strings.clone(path), strings.clone(why)
}

// On the window's thread: what the dump came to, said.
@(private = "file")
dump_done :: proc(data: rawptr, _: u64) {
	j := (^Dump_Task)(data)
	defer dump_lost(j)
	app := the_app
	if app == nil { return }
	app.dump.running = false
	if j.why != "" { say(app, "No dump: %s", j.why); return }
	say(app, "Wrote the dump %s", j.path)
}

@(private = "file")
dump_lost :: proc(data: rawptr) {
	j := (^Dump_Task)(data)
	delete(j.name)
	delete(j.shown)
	delete(j.path)
	delete(j.why)
	free(j)
}
