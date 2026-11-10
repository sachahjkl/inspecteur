package inspecteur

// The Properties dialog of a process (props.odin): resizable, over the window. Its title says which process; its tabs
// show its details, its threads, its open files, its modules, its environment; its foot sets its priority, suspends or
// resumes it, ends or kills it. A list it may not read says "Access denied".

import "core:fmt"
import "core:strings"
import "core:sys/linux"
import "core:time"
import lucide "gt:lucide"
import "gt:ui"

PROPS_W_EM, PROPS_H_EM         :: 58, 40
PROPS_MIN_W_EM, PROPS_MIN_H_EM :: 36, 24
PROPS_ROW_EM                   :: 1.8
PROPS_KEY_EM                   :: 11   // the General tab's labels

props_build :: proc(app: ^App, em: f32) {
	pp := &app.props
	if ui.modal_sized("properties", {em * PROPS_W_EM, em * PROPS_H_EM} * ui.scale(), &pp.size, &pp.open, {em * PROPS_MIN_W_EM, em * PROPS_MIN_H_EM} * ui.scale()) {
		p := find_proc(&app.sampler, pp.pid, pp.start)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###props") {
			props_title(app, p, em)
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
			if ui.row(.Center, {.Draw_Side_Bottom}, "###props_tabs") {
				ui.spacer(ui.px(em * 0.4))
				labels := PROPS_TAB_LABELS
				sel := int(pp.tab)
				nothing: []string
				if ui.tabs("props_tab", props_slice(&labels), nothing, &sel) { pp.tab = Props_Tab(sel) }
			}
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			if ui.column(id = "###props_body") {
				if p == nil {
					props_note("The process has ended.", em)
				} else {
					switch pp.tab {
					case .General:     props_general(app, p, em)
					case .Threads:     props_threads(app, em)
					case .Files:       props_files(app, em)
					case .Modules:     props_modules(app, em)
					case .Environment: props_env(app, em)
					}
				}
			}
			props_actions(app, p, em)
		}
	}
}

@(private = "file")
props_slice :: proc(labels: ^[Props_Tab]string) -> []string { return (cast([^]string)labels)[:len(Props_Tab)] }

@(private = "file")
props_title :: proc(app: ^App, p: ^Proc, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3))})
	if ui.row(.Center, {.Draw_Side_Bottom}, "###props_title") {
		ui.spacer(ui.px(em))
		glyph(app, lucide.INFO, em * 1.8, ui.color("accent"))
		ui.spacer(ui.px(em * 0.4))
		name := p != nil ? p.name : "?"
		ui.next({width = ui.text_size(), height = ui.pct(1), font_size = em * 1.25, text_pad = 0})
		ui.label(fmt.tprintf("%s###props_name", shown_text(name)))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.6})
			ui.label(fmt.tprintf("PID %d%s###props_pid", app.props.pid, p != nil ? fmt.tprintf("  ·  %s", state_text(p.state)) : ""))
		}
		ui.next({width = ui.px(em * 2.2), height = ui.px(em * 2.2), font = app.icons})
		if ui.tags("ghost_button") {
			if ui.button(fmt.tprintf("%s###props_close", lucide.X)).clicked { app.props.open = false }
		}
		ui.spacer(ui.px(em * 0.6))
	}
}

@(private = "file")
props_note :: proc(text: string, em: f32) {
	ui.spacer(ui.px(em * 2))
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(em * 2)})
		if ui.style({text_align = .Center}) { ui.label(fmt.tprintf("%s###note", text)) }
	}
}

// A line of the General tab: its label, its value (wrapped).
@(private = "file")
props_line :: proc(label, value: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.row(.Start, {}, fmt.tprintf("###line_%s", label)) {
		ui.spacer(ui.px(em))
		if ui.tags("weak") {
			ui.next({width = ui.px(em * PROPS_KEY_EM), height = ui.px(em * 1.6), text_pad = 0})
			ui.label(fmt.tprintf("%s###k", label))
		}
		ui.next({width = ui.fill()})
		if ui.style({text_pad = 0}) { ui.paragraph(fmt.tprintf("%s###v", shown_text(value))) }
		ui.spacer(ui.px(em))
	}
	ui.spacer(ui.px(em * 0.25))
}

@(private = "file")
props_general :: proc(app: ^App, p: ^Proc, em: f32) {
	pp := &app.props
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###general") {
		ui.spacer(ui.px(em * 0.8))
		parent := "none"
		for &q in app.sampler.procs { if q.pid == p.ppid { parent = fmt.tprintf("%s (PID %d)", q.name, q.pid) } }
		cwd := pp.cwd
		switch pp.cwd_read {
		case .Read:
		case .Denied: cwd = "Access denied"
		case .Gone:   cwd = "unknown"
		}
		props_line("Name", p.name, em)
		props_line("PID", fmt.tprintf("%d", p.pid), em)
		props_line("Parent", parent, em)
		props_line("User", fmt.tprintf("%s (%d)", user_name(&app.sampler, p.uid), p.uid), em)
		props_line("State", state_text(p.state), em)
		props_line("Priority", fmt.tprintf("nice %d", p.nice), em)
		props_line("Started", started_text(app, p.start), em)
		props_line("Executable", p.exe != "" ? p.exe : "Access denied", em)
		props_line("Command line", p.cmdline != "" ? p.cmdline : "none", em)
		props_line("Working folder", cwd, em)
		props_line("CPU", fmt.tprintf("%.1f%% of the machine", p.cpu), em)
		props_line("Memory", fmt.tprintf("%s resident", size_text(p.rss)), em)
		if p.gpu_mem > 0 { props_line("GPU memory", size_text(p.gpu_mem), em) }
		props_line("Threads", fmt.tprintf("%d", p.threads), em)
		props_line("Disk", p.io_denied ? "Access denied" : fmt.tprintf("%s read, %s written since it started", size_text(p.io_read), size_text(p.io_write)), em)
	}
}

// A list of the dialog: its titles, then its rows (only those in view are built). `cell` gives a row's cells' texts.
@(private = "file")
props_list :: proc(app: ^App, id: string, state: Read_State, titles: []string, widths: []f32, count: int, cell: proc(app: ^App, row, col: int) -> string, em: f32) {
	switch state {
	case .Denied: props_note("Access denied", em); return
	case .Gone:   props_note("The process has ended.", em); return
	case .Read:
	}
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * HEADER_EM)), bg = surface("bar")})
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, fmt.tprintf("###%s_head", id)) {
		ui.spacer(ui.px(em * 0.6))
		if ui.tags("weak") {
			for t, i in titles {
				ui.next({width = widths[i] > 0 ? ui.px(em * widths[i]) : ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###t%d", t, i))
			}
		}
	}
	ids := make([]u64, count, context.temp_allocator)
	for &v, i in ids { v = u64(i) + 1 }
	vl := &app.props_lists[app.props.tab]
	ui.next({width = ui.fill(), height = ui.fill()})
	rows, ok := ui.vlist(fmt.tprintf("###%s", id), vl, ids)
	if !ok { return }
	for i in rows.first ..< rows.last {
		ui.next({height = ui.px(ui.dense(em * PROPS_ROW_EM))})
		row := ui.list_row(vl, i, "")
		if ui.parent(row.box) {
			ui.spacer(ui.px(em * 0.6))
			for _, k in titles {
				if k > 0 { ui.push_tags("weak") }
				ui.next({width = widths[k] > 0 ? ui.px(em * widths[k]) : ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.build_box({.Draw_Text, .Clip}, fmt.tprintf("%s###c%d", shown_text(cell(app, i, k)), k))
				if k > 0 { ui.pop_tags() }
			}
		}
	}
	if count == 0 {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 3)})
			if ui.style({text_align = .Center}) { ui.label("None###empty") }
		}
	}
}

@(private = "file")
props_threads :: proc(app: ^App, em: f32) {
	pp := &app.props
	props_list(app, "threads", pp.threads_read, {"TID", "Name", "State", "CPU time", "Nice"}, {7, 0, 8, 8, 5}, len(pp.threads), proc(app: ^App, row, col: int) -> string {
		t := app.props.threads[row]
		switch col {
		case 0: return fmt.tprintf("%d", t.tid)
		case 1: return t.name
		case 2: return state_text(t.state)
		case 3: return cpu_time_text(t.ticks)
		}
		return fmt.tprintf("%d", t.nice)
	}, em)
}

@(private = "file")
props_files :: proc(app: ^App, em: f32) {
	pp := &app.props
	props_list(app, "files", pp.files_read, {"FD", "What it is open on"}, {5, 0}, len(pp.files), proc(app: ^App, row, col: int) -> string {
		f := app.props.files[row]
		return col == 0 ? fmt.tprintf("%d", f.fd) : f.target
	}, em)
}

@(private = "file")
props_modules :: proc(app: ^App, em: f32) {
	pp := &app.props
	props_list(app, "modules", pp.modules_read, {"File mapped", "Size"}, {0, 8}, len(pp.modules), proc(app: ^App, row, col: int) -> string {
		m := app.props.modules[row]
		return col == 0 ? m.path : size_text(m.size)
	}, em)
}

@(private = "file")
props_env :: proc(app: ^App, em: f32) {
	pp := &app.props
	props_list(app, "environment", pp.env_read, {"Name", "Value"}, {16, 0}, len(pp.env), proc(app: ^App, row, col: int) -> string {
		v := app.props.env[row]
		eq := strings.index_byte(v, '=')
		if eq < 0 { return col == 0 ? v : "" }
		return col == 0 ? v[:eq] : v[eq + 1:]
	}, em)
}

// The dialog's foot: the priority, suspend or resume, end, kill; what the last of them did.
@(private = "file")
props_actions :: proc(app: ^App, p: ^Proc, em: f32) {
	pp := &app.props
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3.2))})
	if ui.row(.Center, {.Draw_Side_Top}, "###props_actions") {
		ui.spacer(ui.px(em))
		if p != nil {
			if ui.tags("weak") {
				ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
				ui.label("Priority###prio_label")
			}
			ui.spacer(ui.px(em * 0.5))
			names: [len(PRIORITIES)]string
			for q, i in PRIORITIES { names[i] = q.name }
			if !ui.ctx_menu_any_open() { pp.nice_sel = priority_index(p.nice) }
			ui.next({width = ui.px(em * 11), height = ui.px(ui.dense(em * 2.1))})
			if ui.dropdown("###priority", names[:], &pp.nice_sel) { set_priority(app, p, PRIORITIES[pp.nice_sel].nice) }
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") {
				msg := ui.now_ms() < app.status_until ? app.status : ""
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = em * 0.9})
				ui.label(fmt.tprintf("%s###props_msg", msg))
			}
			c := Chosen{name = fmt.tprintf("%s (PID %d)", p.name, p.pid)}
			append(&c.targets, Target{p.pid, p.start})
			defer delete(c.targets)
			stopped := p.state == 'T'
			ui.next({height = ui.px(ui.dense(em * 2.1))})
			if ui.button_icon("props_suspend", stopped ? lucide.PLAY : lucide.SQUARE, stopped ? "Resume" : "Suspend").clicked {
				send_signal(app, &c, stopped ? .SIGCONT : .SIGSTOP)
			}
			ui.spacer(ui.px(em * 0.4))
			ui.next({height = ui.px(ui.dense(em * 2.1))})
			if ui.button_icon("props_end", lucide.X, "End task").clicked { send_signal(app, &c, .SIGTERM) }
			ui.spacer(ui.px(em * 0.4))
			ui.next({height = ui.px(ui.dense(em * 2.1))})
			if ui.button_icon("props_kill", lucide.ZAP, "Kill…").clicked { kill_ask(app, c) }
		} else {
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em))
	}
}

// Sets a process's nice value; a user may only lower a priority (setpriority refuses the rest).
@(private = "file")
set_priority :: proc(app: ^App, p: ^Proc, nice: i8) {
	if !proc_alive(&app.sampler, p.pid, p.start) { say(app, "The process has ended already"); return }
	#partial switch linux.setpriority(.PROCESS, p.pid, i32(nice)) {
	case .NONE:
		say(app, "%s (PID %d) now runs at nice %d", p.name, p.pid, nice)
		p.nice = nice
		app.next_sample = time.tick_add(time.tick_now(), SAMPLE_AFTER_SIGNAL)
	case .EACCES, .EPERM:
		say(app, "Access denied: a higher priority, or another user's process, needs root")
	case:
		say(app, "The priority cannot be changed")
	}
}

// CPU time: "12.34 s", "3:05.20" (minutes), "2:03:05" (hours).
cpu_time_text :: proc(ticks: u64) -> string {
	s := f64(ticks) / CLOCK_TICKS
	switch {
	case s < 60:   return fmt.tprintf("%.2f s", s)
	case s < 3600: return fmt.tprintf("%d:%05.2f", int(s) / 60, s - f64(int(s) / 60 * 60))
	}
	return fmt.tprintf("%d:%02d:%02d", int(s) / 3600, (int(s) / 60) % 60, int(s) % 60)
}
