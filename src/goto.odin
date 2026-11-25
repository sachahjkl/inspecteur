package inspecteur

// The palette's Go to (`@`, gui_toolkit's prefix of the things one opens or switches to): the processes of the last
// sample and the services of the last reading, in the plain search too. Choosing one selects its row: a process in
// Processes (the filter cleared, its group open), a service in Services (goto_other.odin: its manager's, the system's or
// the user's; goto_windows.odin).
//
// Each source answers once per version: the processes' when a sample brought a process or took one away
// (Sampler.changes), the services' at each reading (Services.readings). Its answer is built on a chore, in the answer's
// own arena, from a copy of what a line needs: the sampler and the readings are the interface's thread's, and change
// under a chore. A process's id is "<pid>:<start>" (its identity); a process is not remembered (a pid is not the same
// process at the next start), a service is.

import "core:fmt"
import "core:strconv"
import "core:strings"
import i18n "gt:i18n"
import lucide "gt:lucide"
import "gt:ui"

Go_To :: struct {
	processes: ui.Palette_Source,
	services:  ui.Palette_Source,
}

@(private = "file")
Go_To_Proc_Line :: struct {
	pid:   i32,      // Process
	start: u64,      // Process: its identity with the pid
	name:  string,   // owned: Service, Startup
	about: string,
	unit:  string,
}

@(private = "file")
Go_To_Proc_Job :: struct {
	q:       ui.Palette_Question,
	lines:   []Go_To_Proc_Line,
	group:   string,   // "Processes", "Services": translated on the interface's thread
	pid_fmt: string,   // "PID %d", translated
	answer:  ui.Palette_Answer,
}

// The two sources, added once at the start.
go_to_add :: proc(app: ^App) {
	g := &app.go_to
	g.processes = {
		name = "process", title = i18n.later("Processes"), prefix = .Go_To, plain = true, enter = i18n.later("Show"),
		read = go_to_processes_read, poll = proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source) { src.version = (^App)(src.user).sampler.changes },
		user = app,
	}
	g.services = {
		name = "service", title = i18n.later("Services"), prefix = .Go_To, plain = true, remember = true, enter = i18n.later("Show"),
		read = go_to_services_read, poll = proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source) { src.version = (^App)(src.user).services.readings },
		user = app,
	}
	ui.palette_add(&app.palette, &g.processes)
	ui.palette_add(&app.palette, &g.services)
}

// A process's id in the palette: its identity, the pid and its start.
go_to_process_id :: proc(pid: i32, start: u64, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%d:%d", pid, start, allocator = allocator)
}

go_to_process_parse :: proc(id: string) -> (pid: i32, start: u64, ok: bool) {
	colon := strings.index_byte(id, ':')
	if colon <= 0 { return }
	p, pok := strconv.parse_int(id[:colon], 10)
	s, sok := strconv.parse_u64(id[colon + 1:], 10)
	if !pok || !sok || p <= 0 { return }
	return i32(p), s, true
}

// The processes of the last sample but those that ended, copied for the chore.
@(private = "file")
go_to_processes_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	job := new(Go_To_Proc_Job)
	job.q = q
	al := ui.palette_answer_allocator(&job.answer)
	job.group, job.pid_fmt = strings.clone(i18n.tr("Processes"), al), strings.clone(i18n.tr("PID %d"), al)
	lines := make([dynamic]Go_To_Proc_Line, 0, len(app.sampler.procs), al)
	for &pr in app.sampler.procs {
		if pr.ended { continue }
		append(&lines, Go_To_Proc_Line{pid = pr.pid, start = pr.start, name = strings.clone(pr.name, al), about = strings.clone(pr.user, al), unit = strings.clone(pr.unit, al)})
	}
	job.lines = lines[:]
	ui.task(&app.main.state, go_to_proc_work, go_to_proc_done, job, go_to_proc_lost)
}

@(private = "file")
go_to_proc_work :: proc(data: rawptr) {
	job := (^Go_To_Proc_Job)(data)
	al := ui.palette_answer_allocator(&job.answer)
	items := make([]ui.Palette_Item, len(job.lines), al)
	for l, i in job.lines {
		pid := fmt.aprintf(job.pid_fmt, l.pid, allocator = al)
		detail := l.about != "" ? strings.concatenate({pid, "  ·  ", l.about}, al) : pid
		tags: []string
		if l.unit != "" {
			tags = make([]string, 1, al)
			tags[0] = l.unit
		}
		items[i] = {id = go_to_process_id(l.pid, l.start, al), title = l.name, detail = detail, icon = lucide.LAYOUT_LIST, group = job.group, tags = tags}
	}
	job.answer.items = items
}

@(private = "file")
go_to_proc_done :: proc(data: rawptr, _: u64) {
	job := (^Go_To_Proc_Job)(data)
	_ = ui.palette_answer(job.q, &job.answer)
	free(job)
}

@(private = "file")
go_to_proc_lost :: proc(data: rawptr) {
	job := (^Go_To_Proc_Job)(data)
	ui.palette_answer_free(&job.answer)
	ui.palette_question_drop(job.q)
	free(job)
}

// A choice of a Go to source: its row selected.
go_to_chosen :: proc(app: ^App, c: ui.Palette_Choice) {
	if c.source == &app.go_to.processes {
		pid, start, ok := go_to_process_parse(c.id)
		if ok && !processes_reveal(app, pid, start) { say(app, i18n.tr("PID %d is not in the processes' last sample"), pid) }
	} else if c.source == &app.go_to.services {
		go_to_service_chosen(app, c.id)
	}
}
