package inspecteur

// The Information section's model: what the system is. What does not change while the program runs (the system, the
// computer, the processor, the GPUs, the file systems, the screens, the batteries) is read in a job of the chores
// (information_linux.odin: info_read) when the section is first shown, and again on F5: a file system on a network that
// does not answer must not stop the window. What changes (the uptime, the memory, the network's addresses) comes from the
// last sample of Performance (machine.odin) when the section is built.

import "core:mem/virtual"
import tasks "gt:tasks"
import "gt:ui"

Info_Gpu :: struct { name, vendor, ids, driver, slot: string, named: bool }   // named: the device's own name is known
Info_Fs :: struct { mount, device, kind: string, size, free: u64 }
Info_Screen :: struct { connector, name, mode: string }
Info_Battery :: struct { name, status, model, technology: string, capacity, health: int }   // health -1: not told

// What is read on the thread: all of its texts in its arena.
Info_Static :: struct {
	arena:     virtual.Arena,
	os_name, kernel, arch, hostname: string,
	computer, board, firmware: string,
	desktop, session, display: string,
	cpu:       Cpu_Info,
	gpus:      [dynamic]Info_Gpu,
	fss:       [dynamic]Info_Fs,
	screens:   [dynamic]Info_Screen,
	batteries: [dynamic]Info_Battery,
}

Information :: struct {
	job:    tasks.Job,
	demo:   ^Demo,          // not nil: the system is the demo's
	state:  ^ui.State,      // the window a reading is posted to
	data:   ^Info_Static,   // the window's
	asked:  bool,
}

information_init :: proc(inf: ^Information, app: ^App) {
	inf.demo = app.demo
	inf.state = &app.main.state
	inf.job = {work = information_work, data = inf}
}

// After the chores stopped (no reading runs).
information_destroy :: proc(inf: ^Information) {
	info_free(inf.data)
}

@(private = "file")
info_free :: proc(s: ^Info_Static) {
	if s == nil { return }
	virtual.arena_destroy(&s.arena)
	free(s)
}

// Asks for a reading (the first time the section is shown, and on F5).
information_ask :: proc(inf: ^Information) {
	inf.asked = true
	tasks.job_ask(ui.chores(), &inf.job)
}

// Whether a reading is asked or under way.
information_busy :: proc(inf: ^Information) -> bool { return tasks.job_busy(ui.chores(), &inf.job) }

@(private = "file")
information_work :: proc(data: rawptr) {
	inf := (^Information)(data)
	s := new(Info_Static)
	{
		context.allocator = virtual.arena_allocator(&s.arena)
		if inf.demo != nil { demo_info_read(s) } else { info_read(s) }
	}
	if !ui.post(inf.state, information_posted, s) { info_free(s) }
}

// On the window's thread: a new reading replaces the last.
@(private = "file")
information_posted :: proc(data: rawptr, _: u64) {
	s := (^Info_Static)(data)
	if the_app == nil { info_free(s); return }
	inf := &the_app.information
	info_free(inf.data)
	inf.data = s
}

