#+build !windows
package inspecteur

// Palette Go to: systemd services on Linux and macOS.

import "core:fmt"
import "core:strings"
import i18n "gt:i18n"
import lucide "gt:lucide"
import "gt:ui"

@(private = "file")
Go_To_Service_Line :: struct {
	name:    string,
	about:   string,   // a process's user, a service's description
	manager: Manager,
}

@(private = "file")
Go_To_Service_Job :: struct {
	q:      ui.Palette_Question,
	lines:  []Go_To_Service_Line,
	group:  string,
	answer: ui.Palette_Answer,
}

// A service's id in the palette: its manager and its name ("system/sshd.service").
go_to_service_id :: proc(manager: Manager, name: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%s", MANAGER_KEYS[manager], name, allocator = allocator)
}

go_to_service_parse :: proc(id: string) -> (manager: Manager, name: string, ok: bool) {
	slash := strings.index_byte(id, '/')
	if slash <= 0 || slash == len(id) - 1 { return }
	for key, m in MANAGER_KEYS {
		if key == id[:slash] { return m, id[slash + 1:], true }
	}
	return
}

// The services of the last reading (its manager's), copied for the chore.
go_to_services_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	job := new(Go_To_Service_Job)
	job.q = q
	al := ui.palette_answer_allocator(&job.answer)
	job.group = strings.clone(i18n.tr("Services"), al)
	if l := app.services.list; l != nil {
		job.lines = make([]Go_To_Service_Line, len(l.units), al)
		for u, i in l.units { job.lines[i] = {name = strings.clone(u.name, al), about = strings.clone(u.description, al), manager = l.manager} }
	}
	ui.task(&app.main.state, go_to_services_work, go_to_services_done, job, go_to_services_lost)
}

@(private = "file")
go_to_services_work :: proc(data: rawptr) {
	job := (^Go_To_Service_Job)(data)
	al := ui.palette_answer_allocator(&job.answer)
	items := make([]ui.Palette_Item, len(job.lines), al)
	for l, i in job.lines {
		items[i] = {id = go_to_service_id(l.manager, l.name, al), title = l.name, detail = l.about, icon = lucide.SETTINGS, group = job.group}
	}
	job.answer.items = items
}

@(private = "file")
go_to_services_done :: proc(data: rawptr, _: u64) {
	job := (^Go_To_Service_Job)(data)
	_ = ui.palette_answer(job.q, &job.answer)
	free(job)
}

@(private = "file")
go_to_services_lost :: proc(data: rawptr) {
	job := (^Go_To_Service_Job)(data)
	ui.palette_answer_free(&job.answer)
	ui.palette_question_drop(job.q)
	free(job)
}

go_to_service_chosen :: proc(app: ^App, id: string) {
	if manager, name, ok := go_to_service_parse(id); ok { go_to_service_named(app, manager, name) }
}

// The service `name` of `manager` selected in Services (the filter cleared: it could hide it).
go_to_service_named :: proc(app: ^App, manager: Manager, name: string) {
	ui.line_edit_clear(&app.search)
	query_set(app, "")
	services_switch(app, manager)
	tab_show(app, .Services)
	service_select(app, name)
}
