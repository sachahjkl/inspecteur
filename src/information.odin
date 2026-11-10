package inspecteur

// The Information section's model: what the system is. What does not change while the program runs (the system, the
// computer, the processor, the GPUs, the file systems, the screens, the batteries) is read on a thread of its own
// (information_linux.odin: info_read) when the section is first shown, and again on F5: a file system on a network that
// does not answer must not stop the window. What changes (the uptime, the memory, the network's addresses) comes from the
// last sample of Performance (machine.odin) when the section is built.

import "core:mem/virtual"
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
	worker: ui.Worker,
	demo:   ^Demo,          // not nil: the system is the demo's
	shared: ^Info_Static,   // the thread's last reading, under the worker's mutex (taken by the window)
	data:   ^Info_Static,   // the window's
	asked:  bool,
}

information_init :: proc(inf: ^Information, app: ^App) {
	inf.demo = app.demo
	ui.worker_start(&inf.worker, information_job, inf, app.main.win)
}

information_destroy :: proc(inf: ^Information) {
	ui.worker_stop(&inf.worker)
	info_free(inf.shared)
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
	ui.worker_ask(&inf.worker)
}

// The window's turn: a new reading replaces the last.
information_take :: proc(inf: ^Information) {
	if !ui.worker_take(&inf.worker) { return }
	ui.worker_lock(&inf.worker)
	old := inf.data
	inf.data, inf.shared = inf.shared, nil
	ui.worker_unlock(&inf.worker)
	info_free(old)
}

@(private = "file")
information_job :: proc(w: ^ui.Worker) {
	inf := (^Information)(w.user)
	s := new(Info_Static)
	context.allocator = virtual.arena_allocator(&s.arena)
	if inf.demo != nil { demo_info_read(s) } else { info_read(s) }
	ui.worker_lock(w)
	old := inf.shared
	inf.shared = s
	ui.worker_unlock(w)
	info_free(old)
	ui.worker_published(w)
}

