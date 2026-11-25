package inspecteur

// Palette Go to: Windows SCM services.

import "core:strings"
import i18n "gt:i18n"
import lucide "gt:lucide"
import "gt:ui"

@(private = "file")
Go_To_Win_Service_Line :: struct {
	name:    string,
	display: string,
	group:   string,
}

@(private = "file")
Go_To_Win_Service_Job :: struct {
	q:      ui.Palette_Question,
	lines:  []Go_To_Win_Service_Line,
	group:  string,
	answer: ui.Palette_Answer,
}

go_to_services_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	job := new(Go_To_Win_Service_Job)
	job.q = q
	al := ui.palette_answer_allocator(&job.answer)
	job.group = strings.clone(i18n.tr("Services"), al)
	if l := app.services.list; l != nil {
		job.lines = make([]Go_To_Win_Service_Line, len(l.units), al)
		for u, i in l.units {
			job.lines[i] = {
				name    = strings.clone(u.name, al),
				display = strings.clone(u.display_name, al),
				group   = strings.clone(u.svchost_group, al),
			}
		}
	}
	ui.task(&app.main.state, go_to_win_services_work, go_to_win_services_done, job, go_to_win_services_lost)
}

@(private = "file")
go_to_win_services_work :: proc(data: rawptr) {
	job := (^Go_To_Win_Service_Job)(data)
	al := ui.palette_answer_allocator(&job.answer)
	items := make([]ui.Palette_Item, len(job.lines), al)
	for l, i in job.lines {
		tags: []string
		if l.group != "" {
			tags = make([]string, 1, al)
			tags[0] = l.group
		}
		items[i] = {id = l.name, title = l.name, detail = l.display, icon = lucide.SETTINGS, group = job.group, tags = tags}
	}
	job.answer.items = items
}

@(private = "file")
go_to_win_services_done :: proc(data: rawptr, _: u64) {
	job := (^Go_To_Win_Service_Job)(data)
	_ = ui.palette_answer(job.q, &job.answer)
	free(job)
}

@(private = "file")
go_to_win_services_lost :: proc(data: rawptr) {
	job := (^Go_To_Win_Service_Job)(data)
	ui.palette_answer_free(&job.answer)
	ui.palette_question_drop(job.q)
	free(job)
}

go_to_service_chosen :: proc(app: ^App, id: string) {
	if id != "" { go_to_service_named(app, id) }
}

go_to_service_named :: proc(app: ^App, name: string) {
	ui.line_edit_clear(&app.search)
	query_set(app, "")
	listed := false
	if l := app.services.list; l != nil && l.filter == app.services.filter { for u in l.units { if u.name == name { listed = true; break } } }
	if !listed { services_filter_switch(app, .Services) }   // (its filter hides it; selected once a reading lists it)
	tab_show(app, .Services)
	service_select(app, name)
}
