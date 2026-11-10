package inspecteur

// The Properties dialog of a process (props.odin): resizable, over the window. Its title says which process; its tabs
// show its details, its threads, its open files, its modules, its environment; its foot sets its priority, suspends or
// resumes it, ends or kills it. A list it may not read says "Access denied". Its keys are the Properties group's of
// commands.odin (Ctrl+Tab, Ctrl+P, Delete, Shift+Delete, Ctrl+Up, Ctrl+Down, Escape).

import "core:fmt"
import "core:strings"
import lucide "gt:lucide"
import "gt:ui"

PROPS_W_EM, PROPS_H_EM         :: 58, 40
PROPS_MIN_W_EM, PROPS_MIN_H_EM :: 36, 24
PROPS_ROW_EM                   :: 1.8
PROPS_KEY_EM                   :: 11   // the General tab's labels

props_build :: proc(app: ^App, em: f32) {
	pp := &app.props
	if pp.open && !app.menu.confirm.open && !app.affinity.open && !ui.ctx_menu_any_open() { props_keys(app) }
	if ui.modal_sized("properties", {em * PROPS_W_EM, em * PROPS_H_EM} * ui.scale(), &pp.size, &pp.open, {em * PROPS_MIN_W_EM, em * PROPS_MIN_H_EM} * ui.scale()) {
		p := find_proc(&app.sampler, pp.pid, pp.start)
		if pp.tab != pp.read_tab && p != nil { props_read(pp) }   // (a tab shown is read at once)
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
				// (each tab's tooltip says the keys that go from tab to tab)
				tabs_tip := fmt.tprintf("%s (%s), %s (%s)", COMMANDS[.Props_Next_Tab].label, ui.command_shortcut(COMMANDS[.Props_Next_Tab]), COMMANDS[.Props_Previous_Tab].label, ui.command_shortcut(COMMANDS[.Props_Previous_Tab]))
				for i in 0 ..< len(Props_Tab) { hover_tip(fmt.tprintf("props_tab_%d", i), tabs_tip) }
				ui.spacer(ui.fill())
				if props_tab_listed(pp.tab) { props_filter_field(app, em) }
			}
			ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
			if ui.column(id = "###props_body") {
				if p == nil || pp.gone {
					props_note("The process has ended.", em)
				} else {
					switch pp.tab {
					case .General:     props_general(app, p, em)
					case .History:     props_history(app, p, em)
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
		ui.label(fmt.tprintf("%s###props_name", ui.text_shown(name)))
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = em * 0.6})
			ui.label(fmt.tprintf("PID %d%s###props_pid", app.props.pid, p != nil ? fmt.tprintf("  ·  %s", state_text(p.state)) : ""))
		}
		ui.next({width = ui.px(em * 2.2), height = ui.px(em * 2.2), font = app.icons})
		sig: ui.Signal
		if ui.tags("ghost_button") { sig = ui.button(fmt.tprintf("%s###props_close", lucide.X)) }
		if sig.clicked { app.props.open = false }
		tip_after(sig, cmd_tip(.Props_Close))
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
		// (both paragraphs: their first lines share a baseline)
		if ui.tags("weak") {
			ui.next({width = ui.px(em * PROPS_KEY_EM)})
			if ui.style({text_pad = 0}) { ui.paragraph(fmt.tprintf("%s###k", label)) }
		}
		ui.next({width = ui.fill()})
		if ui.style({text_pad = 0}) { ui.paragraph(fmt.tprintf("%s###v", ui.text_shown(value))) }
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
		case .Denied: cwd = "Access denied (another user's process)"
		case .Gone:   cwd = "unknown"
		}
		props_line("Name", p.name, em)
		props_line("PID", fmt.tprintf("%d", p.pid), em)
		props_line("Parent", parent, em)
		props_line("User", p.user != "" ? p.user : "unknown", em)
		props_line("State", state_text(p.state), em)
		props_line("Priority", priority_text(p.nice), em)
		props_line("Affinity", pp.cpus != "" ? fmt.tprintf("processors %s", pp.cpus) : "unknown", em)
		props_line("Started", started_text(app, p.started), em)
		props_line("Executable", p.exe != "" ? p.exe : "Access denied (another user's process)", em)
		props_line("Command line", p.cmdline != "" ? p.cmdline : "none", em)
		props_line("Working folder", cwd, em)
		props_line("CPU", fmt.tprintf("%.1f%% of the machine", p.cpu), em)
		props_line("Memory", fmt.tprintf("%s private, %s resident (with the pages it shares with other processes)", size_text(p.private), size_text(p.resident)), em)
		if p.gpu_mem > 0 { props_line("GPU memory", size_text(p.gpu_mem), em) }
		if p.gpu > 0 { props_line("GPU", fmt.tprintf("%.0f%% of a GPU's time", p.gpu), em) }
		props_line("Threads", fmt.tprintf("%d", p.threads), em)
		props_line("Disk", !p.io_known ? "Access denied (another user's process)" : fmt.tprintf("%s read, %s written since it started", size_text(p.io_read), size_text(p.io_write)), em)
	}
}

// The History tab: the process's CPU, memory and disk since Inspecteur saw it start (PROC_HISTORY_POINTS samples at
// most), a graph each with its span, its top and its last value.
@(private = "file")
props_history :: proc(app: ^App, p: ^Proc, em: f32) {
	if p.hist == nil || p.hist.cpu.count < 2 {
		props_note("Its history starts at the next samples.", em)
		return
	}
	h := p.hist
	period := app.settings.refresh_ms
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###history") {
		ui.spacer(ui.px(em * 0.6))
		graph :: proc(id, what: string, hist: ^ui.Value_History(PROC_HISTORY_POINTS), color: ui.Color, top, floor: f32, value: proc(v: f32) -> string, period: int, em: f32) {
			values := ui.value_history_values(hist)
			series := []ui.Line_Series{{values, color}}
			shown_top := ui.line_graph_top(series, {top = top, floor = floor})
			ui.next({width = ui.fill(), height = ui.px(em * 1.5)})
			if ui.row(.Center, {}, fmt.tprintf("###%s_caption", id)) {
				ui.spacer(ui.px(em))
				ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s  %s###l", what, value(ui.value_history_last(hist))))
				ui.spacer(ui.fill())
				if ui.tags("weak") {
					ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0, font_size = em * 0.85})
					ui.label(fmt.tprintf("%s, top %s###r", span_text(hist.count, period), value(shown_top)))
				}
				ui.spacer(ui.px(em))
			}
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.row(id = fmt.tprintf("###%s_row", id)) {
				ui.spacer(ui.px(em))
				ui.next({width = ui.fill(), height = ui.pct(1)})
				// (the whole history across the width, at least a minute's points: it spreads as it grows)
				ui.line_graph(fmt.tprintf("###%s", id), series, {top = shown_top, points = max(hist.count, HISTORY_POINTS), grid = true})
				ui.spacer(ui.px(em))
			}
			ui.spacer(ui.px(em * 0.5))
		}
		graph("hist_cpu", "CPU", &h.cpu, hue(app, HUE_CPU), 0, 5, proc(v: f32) -> string { return fmt.tprintf("%.1f%%", v) }, period, em)
		graph("hist_memory", "Private memory", &h.memory, hue(app, HUE_MEMORY), 0, 16 * 1024 * 1024, proc(v: f32) -> string { return size_text(u64(v)) }, period, em)
		if p.io_known {
			graph("hist_disk", "Disk", &h.disk, hue(app, HUE_DISK), 0, DISK_FLOOR, proc(v: f32) -> string { return fmt.tprintf("%s/s", size_text(u64(v))) }, period, em)
		}
	}
}

// A list of the dialog: its titles, then its rows (only those in view are built). `cell` gives a row's cells' texts.
@(private = "file")
props_list :: proc(app: ^App, id: string, state: Read_State, titles: []string, widths: []f32, count: int, cell: proc(app: ^App, row, col: int) -> string, em: f32) {
	switch state {
	case .Denied: props_note(fmt.tprintf("Access denied: another user's process. Only its owner, or %s, may read it.", ADMIN), em); return
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
	// (the rows the filter keeps: a row whose cells hold its text)
	q := strings.to_lower(ui.field_string(&app.props.filter), context.temp_allocator)
	shown := make([dynamic]int, 0, count, context.temp_allocator)
	for i in 0 ..< count {
		keep := q == ""
		for k := 0; !keep && k < len(titles); k += 1 { keep = strings.contains(strings.to_lower(cell(app, i, k), context.temp_allocator), q) }
		if keep { append(&shown, i) }
	}
	ids := make([]u64, len(shown), context.temp_allocator)
	for &v, i in ids { v = u64(shown[i]) + 1 }
	vl := &app.props_lists[app.props.tab]
	rows_look(app, vl)
	ui.next({width = ui.fill(), height = ui.fill()})
	rows, ok := ui.vlist(fmt.tprintf("###%s", id), vl, ids)
	if !ok { return }
	for i in rows.first ..< rows.last {
		ui.next({height = ui.px(ui.dense(em * PROPS_ROW_EM))})
		row := ui.list_row(vl, i, "")
		tip := ""
		if ui.parent(row.box) {
			ui.spacer(ui.px(em * 0.6))
			for _, k in titles {
				if k > 0 { ui.push_tags("weak") }
				text := cell(app, shown[i], k)
				ui.next({width = widths[k] > 0 ? ui.px(em * widths[k]) : ui.fill(), height = ui.pct(1), text_pad = 0})
				b := ui.build_box({.Draw_Text, .Clip}, fmt.tprintf("%s###c%d", ui.text_shown(text), k))
				// (a cell too narrow for its text shows it whole when the pointer rests on its row)
				if text_cut(b, text) { tip = text }
				if k > 0 { ui.pop_tags() }
			}
		}
		ui.table_cell_tip(row, tip)
	}
	if len(shown) == 0 {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 3)})
			if ui.style({text_align = .Center}) { ui.label(count == 0 ? "None###empty" : fmt.tprintf("Nothing matches “%s”.###empty", ui.text_shown(q))) }
		}
	}
}

@(private = "file")
props_threads :: proc(app: ^App, em: f32) {
	pp := &app.props
	props_list(app, "threads", pp.list_read, {"TID", "Name", "State", "CPU time", "Nice"}, {7, 0, 8, 8, 5}, len(pp.threads), proc(app: ^App, row, col: int) -> string {
		t := app.props.threads[row]
		switch col {
		case 0: return fmt.tprintf("%d", t.tid)
		case 1: return t.name
		case 2: return state_text(t.state)
		case 3: return cpu_time_text(t.cpu_ns)
		}
		return fmt.tprintf("%d", t.nice)
	}, em)
}

@(private = "file")
props_files :: proc(app: ^App, em: f32) {
	pp := &app.props
	props_list(app, "files", pp.list_read, {"FD", "What it is open on"}, {5, 0}, len(pp.files), proc(app: ^App, row, col: int) -> string {
		f := app.props.files[row]
		return col == 0 ? fmt.tprintf("%d", f.fd) : f.target
	}, em)
}

@(private = "file")
props_modules :: proc(app: ^App, em: f32) {
	pp := &app.props
	props_list(app, "modules", pp.list_read, {"File mapped", "Size"}, {0, 8}, len(pp.modules), proc(app: ^App, row, col: int) -> string {
		m := app.props.modules[row]
		return col == 0 ? m.path : size_text(m.size)
	}, em)
}

@(private = "file")
props_env :: proc(app: ^App, em: f32) {
	pp := &app.props
	props_list(app, "environment", pp.list_read, {"Name", "Value"}, {16, 0}, len(pp.env), proc(app: ^App, row, col: int) -> string {
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
		if p != nil && !pp.gone {
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
			hover_tip("priority", fmt.tprintf("%s (%s), %s (%s)", COMMANDS[.Props_Raise_Priority].label, ui.command_shortcut(COMMANDS[.Props_Raise_Priority]), COMMANDS[.Props_Lower_Priority].label, ui.command_shortcut(COMMANDS[.Props_Lower_Priority])))
			ui.spacer(ui.px(em * 0.4))
			if props_button(app, "props_affinity", lucide.MICROCHIP, "Affinity…", .Props_Affinity, em) { cmd_run(app, .Props_Affinity) }
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") {
				msg := ui.now_ms() < app.status_until ? app.status : ""
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = em * 0.9})
				label_tip(fmt.tprintf("%s###props_msg", ui.text_shown(msg)), msg)
			}
			stopped := p.state == .Stopped
			if props_button(app, "props_suspend", stopped ? lucide.PLAY : lucide.SQUARE, stopped ? "Resume" : "Suspend", .Props_Suspend, em) { props_suspend(app) }
			ui.spacer(ui.px(em * 0.4))
			if props_button(app, "props_end", lucide.X, "End task", .Props_End_Task, em) { props_signal(app, false) }
			ui.spacer(ui.px(em * 0.4))
			if props_button(app, "props_kill", lucide.ZAP, "Kill…", .Props_Kill, em) { props_signal(app, true) }
		} else {
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em))
	}
}

// A button of the foot: its icon and its label; its tooltip says its key.
@(private = "file")
props_button :: proc(app: ^App, id, icon, label: string, c: Cmd, em: f32) -> bool {
	ui.next({height = ui.px(ui.dense(em * 2.1))})
	sig := ui.button_icon(id, icon, label)
	tip_after(sig, fmt.tprintf("%s (%s)", label, ui.command_shortcut(COMMANDS[c])))
	return sig.clicked
}

// The keys of the dialog (the Properties group of commands.odin). While its filter has the keyboard and some text, the
// filter keeps its editing keys (Delete erases a character there, not the process).
@(private = "file")
props_keys :: proc(app: ^App) {
	pp := &app.props
	keeps := ui.focus_key() == pp.filter_key && pp.filter_key != 0 && len(pp.filter.buf) > 0
	for c in Cmd {
		if !cmd_is_props(c) || c == .Props_Close { continue }   // (Escape: the dialog's own)
		if keeps && (c == .Props_End_Task || c == .Props_Kill) { continue }
		if ui.command_pressed(COMMANDS[c], cmd_can(app, c)) { cmd_run(app, c) }
	}
}

// The filter of the dialog's lists, at the right of its tabs.
@(private = "file")
props_filter_field :: proc(app: ^App, em: f32) {
	pp := &app.props
	ui.next({width = ui.px(em * 14), height = ui.px(ui.dense(em * 2))})
	res := ui.line_edit("###props_filter", &pp.filter, "Filter the list...")
	pp.filter_key = res.box.key
	tip_after(res, cmd_tip(.Props_Filter))
	ui.spacer(ui.px(em * 0.6))
}

// Ctrl+F in the dialog: its filter gets the keyboard (on the General tab, the Threads tab is shown first).
props_filter_focus :: proc(app: ^App) {
	pp := &app.props
	if !props_tab_listed(pp.tab) { pp.tab = .Threads }
	if pp.filter_key != 0 { ui.set_focus(pp.filter_key) }
}

// A tooltip on the box `name` of the box being built (its id "###name"), while the pointer rests on it.
hover_tip :: proc(name, text: string) {
	key := ui.key_from_string(ui.parent_box().key, fmt.tprintf("###%s", name))
	tip_after(ui.Signal{hovering = ui.hot_key() == key}, text)
}

// Suspend or resume, from the dialog.
props_suspend :: proc(app: ^App) {
	if p := find_proc(&app.sampler, app.props.pid, app.props.start); p != nil { suspend_or_resume(app, p) }
}

// End task or Kill (asked first), from the dialog.
props_signal :: proc(app: ^App, kill: bool) {
	p := find_proc(&app.sampler, app.props.pid, app.props.start)
	if p == nil { return }
	c := Chosen{name = fmt.tprintf("%s (PID %d)", p.name, p.pid)}
	append(&c.targets, Target{p.pid, p.start})
	defer delete(c.targets)
	if kill { confirm_ask(app, c, .Kill) } else { signal_or_confirm(app, &c, .Terminate) }
}
