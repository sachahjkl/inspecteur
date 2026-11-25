package inspecteur

// Windows Properties view (props_windows.odin): 7 Windows-native tabs:
// General (UWP, WOW64, svchost, commit/peak/faults), History, Security & Resources
// (Integrity, Elevation, PPL, Critical, EcoQoS, GDI/USER objects + peaks, Pools, Token Privileges),
// Threads & Wait Chain (deadlock banner + wait reasons + blocking chains), Handles, Modules, Environment.

import "core:fmt"
import "core:strings"
import i18n "gt:i18n"
import lucide "gt:lucide"
import "gt:ui"
import timefmt "gt:timefmt"
import winapi "winapi"

PROPS_W_EM, PROPS_H_EM         :: 62, 42
PROPS_MIN_W_EM, PROPS_MIN_H_EM :: 38, 26
PROPS_ROW_EM                   :: 1.8
PROPS_KEY_EM                   :: 13

props_register :: proc(app: ^App) {
	ui.view_register(&app.views, PROPS_VIEW, props_view, ui.View_Options{
		title = i18n.later("Properties"), icon = lucide.INFO, resizable = true,
		width_em = PROPS_W_EM, height_em = PROPS_H_EM, min_width_em = PROPS_MIN_W_EM, min_height_em = PROPS_MIN_H_EM,
	})
}

@(private = "file")
props_view :: proc(v: ^ui.View, app: ^App) {
	pp := &app.props
	em := ui.font_size()
	if v.shown { props_keys(app) }
	p := find_proc(&app.sampler, pp.pid, pp.start)
	if p != nil && !pp.gone && (pp.data == nil || pp.tab != pp.data.read_tab) { props_read(app) }
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###props") {
		props_title(app, p, em)
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.4))})
		if ui.row(.Center, {.Draw_Side_Bottom}, "###props_tabs") {
			ui.space(ui.SPACE_2)
			labels := PROPS_TAB_LABELS
			for &l in labels { l = i18n.tr(l) }
			sel := int(pp.tab)
			nothing: []string
			if ui.tabs("props_tab", (cast([^]string)&labels)[:len(Props_Tab)], nothing, &sel) { pp.tab = Props_Tab(sel) }
			tabs_tip := fmt.tprintf("%s (%s), %s (%s)", cmd_label(.Props_Next_Tab), ui.command_shortcut(COMMANDS[.Props_Next_Tab]), cmd_label(.Props_Previous_Tab), ui.command_shortcut(COMMANDS[.Props_Previous_Tab]))
			for i in 0 ..< len(Props_Tab) { hover_tip(fmt.tprintf("props_tab_%d", i), tabs_tip) }
			ui.spacer(ui.fill())
			if props_tab_listed(pp.tab) { props_filter_field(app, em) }
		}
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###props_body") {
			if p == nil || pp.gone {
				props_note(i18n.tr("The process has ended."), em)
			} else {
				switch pp.tab {
				case .General:     props_general(app, p, em)
				case .History:     props_history(app, p, em)
				case .Security:    props_security(app, p, em)
				case .Threads:     props_threads(app, em)
				case .Handles:     props_handles(app, em)
				case .Modules:     props_modules(app, em)
				case .Environment: props_env(app, em)
				}
			}
		}
		props_actions(app, p, em)
	}
}

@(private = "file")
props_title :: proc(app: ^App, p: ^Proc, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.6))})
	if ui.row(.Center, {}, "###props_title") {
		ui.space(ui.SPACE_4)
		name := p != nil ? p.name : "?"
		ui.next({width = ui.text_size(), height = ui.pct(1), font_size = em * 1.25, text_pad = 0, flags = {.Selectable}})
		ui.label(fmt.tprintf("%s###props_name", ui.text_shown(name)))
		if ui.tags("weak") {
			ui.space(ui.SPACE_2)
			bits := ""
			if p != nil {
				parts := make([dynamic]string, context.temp_allocator)
				append(&parts, fmt.tprintf(i18n.tr("PID %d"), app.props.pid))
				append(&parts, state_text(p.state))
				if p.extra.wow64 { append(&parts, "32-bit (WOW64)") }
				if p.extra.elevated { append(&parts, i18n.tr("Elevated")) }
				if p.extra.efficiency { append(&parts, i18n.tr("Efficiency mode")) }
				bits = strings.join(parts[:], "  ·  ", context.temp_allocator)
			} else {
				bits = fmt.tprintf(i18n.tr("PID %d"), app.props.pid)
			}
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, flags = {.Selectable}})
			ui.label(fmt.tprintf("%s###props_pid", bits))
		}
		ui.space(ui.SPACE_2)
	}
}

@(private = "file")
props_note :: proc(text: string, em: f32) {
	ui.space(ui.SPACE_6)
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.px(em * 2)})
		if ui.style({text_align = .Center}) { ui.label(fmt.tprintf("%s###note", text)) }
	}
}

@(private = "file")
props_line :: proc(label, value: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.row(.Start, {}, fmt.tprintf("###line_%s", label)) {
		ui.space(ui.SPACE_4)
		if ui.tags("weak") {
			ui.next({width = ui.px(em * PROPS_KEY_EM)})
			if ui.style({text_pad = 0}) { ui.paragraph(fmt.tprintf("%s###k", label)) }
		}
		ui.next({width = ui.fill()})
		if ui.style({text_pad = 0}) { ui.paragraph(fmt.tprintf("%s###v", ui.text_shown(value))) }
		ui.space(ui.SPACE_4)
	}
	ui.space(ui.SPACE_1)
}

@(private = "file")
props_general :: proc(app: ^App, p: ^Proc, em: f32) {
	pp := &app.props
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###general") {
		ui.space(ui.SPACE_3)
		parent := i18n.tr("none")
		if q := find_pid(&app.sampler, p.ppid); q != nil { parent = fmt.tprintf(i18n.tr("%s (PID %d)"), q.name, q.pid) }
		cwd, cpus := "…", ""
		if d := pp.data; d != nil && d.read_tab == .General {
			cwd, cpus = d.cwd, d.cpus
			switch d.cwd_read {
			case .Read:
			case .Denied: cwd = i18n.tr("Access denied (requires administrator or unprotected process)")
			case .Gone:   cwd = i18n.tr("unknown")
			}
		}
		props_line(i18n.tr("Name"), p.name, em)
		props_line(i18n.tr("PID"), fmt.tprintf("%d", p.pid), em)
		props_line(i18n.tr("Session"), fmt.tprintf("%d", p.extra.session_id), em)
		props_line(i18n.tr("Parent"), parent, em)
		props_line(i18n.tr("User"), p.user != "" ? p.user : i18n.tr("unknown"), em)
		props_line(i18n.tr("Architecture"), p.extra.wow64 ? i18n.tr("32-bit (WOW64)") : i18n.tr("64-bit"), em)
		props_line(i18n.tr("State"), state_text(p.state), em)
		props_line(i18n.tr("Priority"), priority_text(p.nice), em)
		props_line(i18n.tr("Efficiency mode"), p.extra.efficiency ? i18n.tr("On (EcoQoS)") : i18n.tr("Off"), em)
		props_line(i18n.tr("Affinity"), cpus != "" ? fmt.tprintf(i18n.tr("processors %s"), cpus) : i18n.tr("unknown"), em)
		props_line(i18n.tr("Started"), started_text(app, p.started), em)
		if p.extra.uwp_package != "" { props_line(i18n.tr("UWP package"), p.extra.uwp_package, em) }
		if p.extra.svchost_group != "" { props_line(i18n.tr("svchost group"), p.extra.svchost_group, em) }
		if p.extra.service_names != "" { props_line(i18n.tr("Hosted services"), p.extra.service_names, em) }
		props_line(i18n.tr("Executable"), p.exe != "" ? p.exe : i18n.tr("Access denied"), em)
		props_line(i18n.tr("Command line"), p.cmdline != "" ? p.cmdline : i18n.tr("none"), em)
		props_line(i18n.tr("Working folder"), cwd, em)
		props_line(i18n.tr("CPU"), fmt.tprintf(i18n.tr("%s of the machine"), percent_text(f64(p.cpu), 1)), em)
		props_line(i18n.tr("Memory"), fmt.tprintf(i18n.tr("%s private, %s working set (peak %s), %s commit"),
			timefmt.size(i64(p.private)), timefmt.size(i64(p.resident)), timefmt.size(i64(p.extra.peak_working_set)), timefmt.size(i64(p.extra.commit))), em)
		props_line(i18n.tr("Page faults"), fmt.tprintf("%d", p.extra.page_faults), em)
		if p.gpu_mem > 0 { props_line(i18n.tr("GPU memory"), timefmt.size(i64(p.gpu_mem)), em) }
		if p.gpu > 0 { props_line(i18n.tr("GPU"), fmt.tprintf(i18n.tr("%s of a GPU's time"), percent_text(f64(p.gpu))), em) }
		props_line(i18n.tr("Threads & Handles"), fmt.tprintf(i18n.tr("%d threads, %d handles"), p.threads, p.extra.handles), em)
		props_line(i18n.tr("Disk"), fmt.tprintf(i18n.tr("%s read, %s written since it started"), timefmt.size(i64(p.io_read)), timefmt.size(i64(p.io_write))), em)
	}
}

@(private = "file")
props_history :: proc(app: ^App, p: ^Proc, em: f32) {
	if p.hist == nil || p.hist.cpu.count < 2 {
		props_note(i18n.tr("Its history starts at the next samples."), em)
		return
	}
	h := p.hist
	period := app.settings.refresh_ms
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
	if ui.column(id = "###history") {
		ui.space(ui.SPACE_2)
		graph :: proc(id, what: string, hist: ^ui.Value_History(PROC_HISTORY_POINTS), color: ui.Color, top, floor: f32, value: proc(v: f32) -> string, period: int, em: f32) {
			values := ui.value_history_values(hist)
			series := []ui.Line_Series{{values, color}}
			shown_top := ui.line_graph_top(series, {top = top, floor = floor})
			ui.next({width = ui.fill(), height = ui.px(em * 1.5)})
			if ui.row(.Center, {}, fmt.tprintf("###%s_caption", id)) {
				ui.space(ui.SPACE_4)
				ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s  %s###l", what, value(ui.value_history_last(hist))))
				ui.spacer(ui.fill())
				if ui.tags("weak") {
					ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0, font_size = em * 0.85})
					ui.label(fmt.tprintf("%s###r", fmt.tprintf(i18n.tr("%s, top %s"), span_text(hist.count, period), value(shown_top))))
				}
				ui.space(ui.SPACE_4)
			}
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.row(id = fmt.tprintf("###%s_row", id)) {
				ui.space(ui.SPACE_4)
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.line_graph(fmt.tprintf("###%s", id), series, {top = shown_top, points = max(hist.count, HISTORY_POINTS), grid = true})
				ui.space(ui.SPACE_4)
			}
			ui.space(ui.SPACE_2)
		}
		graph("hist_cpu", i18n.tr("CPU"), &h.cpu, hue(app, HUE_CPU), 0, 5, proc(v: f32) -> string { return percent_text(f64(v), 1) }, period, em)
		graph("hist_memory", i18n.tr("Private memory"), &h.memory, hue(app, HUE_MEMORY), 0, 16 * 1024 * 1024, proc(v: f32) -> string { return timefmt.size(i64(v)) }, period, em)
		graph("hist_disk", i18n.tr("Disk"), &h.disk, hue(app, HUE_DISK), 0, DISK_FLOOR, proc(v: f32) -> string { return timefmt.rate(f64(v)) }, period, em)
	}
}

@(private = "file")
props_security :: proc(app: ^App, p: ^Proc, em: f32) {
	d := app.props.data
	prot_label, prot := winapi.decode_protection_level(p.extra.protection)
	ui.space(ui.SPACE_2)
	props_line(i18n.tr("Integrity level"), integrity_label(p.extra.integrity) != "" ? integrity_label(p.extra.integrity) : i18n.tr("Unknown"), em)
	props_line(i18n.tr("Elevation"), p.extra.elevated ? i18n.tr("Elevated (Administrator)") : i18n.tr("Standard"), em)
	props_line(i18n.tr("Protection"), prot ? prot_label : i18n.tr("None"), em)
	props_line(i18n.tr("Critical process"), p.extra.critical ? i18n.tr("Yes (terminating it crashes Windows)") : i18n.tr("No"), em)
	if d != nil && d.read_tab == .Security {
		props_line(i18n.tr("GDI / USER objects"), fmt.tprintf(i18n.tr("GDI: %d (peak %d)  ·  USER: %d (peak %d)"), d.gdi_objects, d.gdi_peak, d.user_objects, d.user_peak), em)
	}
	props_line(i18n.tr("Kernel pools"), fmt.tprintf(i18n.tr("Paged %s  ·  Non-paged %s"), timefmt.size(i64(p.extra.paged_pool)), timefmt.size(i64(p.extra.nonpaged_pool))), em)
	ui.hline(ui.fill())
	props_list(app, "privileges", {i18n.tr("Token privilege"), i18n.tr("State")}, {0, 16}, proc(d: ^Props_Data) -> int { return len(d.privileges) }, proc(app: ^App, row, col: int) -> string {
		pr := app.props.data.privileges[row]
		return col == 0 ? pr.name : pr.state
	}, em)
}

@(private = "file")
props_threads :: proc(app: ^App, em: f32) {
	if d := app.props.data; d != nil && d.read_tab == .Threads && d.has_deadlock {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.1)), bg = surface("bar")})
		if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###wct_deadlock") {
			ui.space(ui.SPACE_3)
			if ui.tags("bad") {
				ui.icon(lucide.ALERT_TRIANGLE, em * 1.4)
				ui.space(ui.ICON_GAP)
				ui.label(fmt.tprintf("%s###t", i18n.tr("Deadlock detected by Windows Wait Chain Traversal")))
			}
		}
	}
	props_list(app, "threads",
		{i18n.tr("TID"), i18n.tr("State"), i18n.tr("Wait reason"), i18n.tr("CPU time"), i18n.tr("Priority"), i18n.tr("Wait chain")},
		{7, 9, 13, 8, 6, 0},
		proc(d: ^Props_Data) -> int { return len(d.threads) },
		proc(app: ^App, row, col: int) -> string {
			t := app.props.data.threads[row]
			switch col {
			case 0: return fmt.tprintf("%d", t.tid)
			case 1: return t.state
			case 2: return t.wait_reason
			case 3: return cpu_time_text(t.cpu_ns)
			case 4: return fmt.tprintf("%d", t.priority)
			}
			return t.wait_chain
		}, em)
}

@(private = "file")
props_handles :: proc(app: ^App, em: f32) {
	if d := app.props.data; d != nil && d.read_tab == .Handles && d.handles_total > len(d.handles) {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.8))})
		if ui.row(.Center, {.Draw_Side_Bottom}, "###handles_cap") {
			ui.space(ui.SPACE_3)
			if ui.tags("weak") {
				ui.label(fmt.tprintf(i18n.tr("Showing first %d of %d handles"), len(d.handles), d.handles_total))
			}
		}
	}
	props_list(app, "handles",
		{i18n.tr("Handle"), i18n.tr("Type"), i18n.tr("Access"), i18n.tr("Object name")},
		{7, 12, 9, 0},
		proc(d: ^Props_Data) -> int { return len(d.handles) },
		proc(app: ^App, row, col: int) -> string {
			h := app.props.data.handles[row]
			switch col {
			case 0: return fmt.tprintf("0x%X", h.handle)
			case 1: return h.type
			case 2: return fmt.tprintf("0x%08X", h.access)
			}
			return h.name
		}, em)
}

@(private = "file")
props_modules :: proc(app: ^App, em: f32) {
	props_list(app, "modules",
		{i18n.tr("Module path"), i18n.tr("Base address"), i18n.tr("Size")},
		{0, 14, 8},
		proc(d: ^Props_Data) -> int { return len(d.modules) },
		proc(app: ^App, row, col: int) -> string {
			m := app.props.data.modules[row]
			switch col {
			case 0: return m.path
			case 1: return fmt.tprintf("0x%016X", m.base)
			}
			return timefmt.size(i64(m.size))
		}, em)
}

@(private = "file")
props_env :: proc(app: ^App, em: f32) {
	props_list(app, "environment", {i18n.tr("Name"), i18n.tr("Value")}, {18, 0}, proc(d: ^Props_Data) -> int { return len(d.env) }, proc(app: ^App, row, col: int) -> string {
		v := app.props.data.env[row]
		eq := strings.index_byte(v, '=')
		if eq < 0 { return col == 0 ? v : "" }
		return col == 0 ? v[:eq] : v[eq + 1:]
	}, em)
}

@(private = "file")
props_list :: proc(app: ^App, id: string, titles: []string, widths: []f32, count: proc(d: ^Props_Data) -> int, cell: proc(app: ^App, row, col: int) -> string, em: f32) {
	pp := &app.props
	d := pp.data
	if d == nil || d.read_tab != pp.tab { return }
	switch d.list_read {
	case .Denied:
		props_note(i18n.tr("Access denied: run Inspecteur as an administrator (protected processes remain blocked)."), em)
		return
	case .Gone:
		props_note(i18n.tr("The process has ended."), em)
		return
	case .Read:
	}
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * HEADER_EM)), bg = surface("bar")})
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, fmt.tprintf("###%s_head", id)) {
		ui.space(ui.SPACE_2)
		if ui.tags("weak") {
			for t, i in titles {
				ui.next({width = widths[i] > 0 ? ui.px(em * widths[i]) : ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###t%d", t, i))
			}
		}
	}
	n := count(d)
	q := strings.to_lower(ui.line_edit_string(&pp.filter), context.temp_allocator)
	if pp.shown_of != pp.serial || pp.shown_tab != pp.tab || pp.shown_query != q {
		pp.shown_of, pp.shown_tab = pp.serial, pp.tab
		delete(pp.shown_query)
		pp.shown_query = strings.clone(q)
		clear(&pp.shown)
		clear(&pp.shown_ids)
		for i in 0 ..< n {
			keep := q == ""
			for k := 0; !keep && k < len(titles); k += 1 {
				keep = strings.contains(strings.to_lower(cell(app, i, k), context.temp_allocator), q)
			}
			if keep {
				append(&pp.shown, i)
				append(&pp.shown_ids, u64(i) + 1)
			}
		}
	}
	shown, ids := pp.shown[:], pp.shown_ids[:]
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
			ui.space(ui.SPACE_2)
			for _, k in titles {
				if k > 0 { ui.push_tags("weak") }
				text := cell(app, shown[i], k)
				ui.next({width = widths[k] > 0 ? ui.px(em * widths[k]) : ui.fill(), height = ui.pct(1), text_pad = 0})
				b := ui.build_box({.Draw_Text, .Clip}, fmt.tprintf("%s###c%d", ui.text_shown(text), k))
				if text_cut(b, text) { tip = text }
				if k > 0 { ui.pop_tags() }
			}
		}
		ui.table_cell_tip(row, tip)
	}
	if len(shown) == 0 {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 3)})
			if ui.style({text_align = .Center}) {
				ui.label(fmt.tprintf("%s###empty", n == 0 ? i18n.tr("None") : fmt.tprintf(i18n.tr("Nothing matches “%s”."), ui.text_shown(q))))
			}
		}
	}
}

@(private = "file")
props_actions :: proc(app: ^App, p: ^Proc, em: f32) {
	pp := &app.props
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 3.2))})
	if ui.row(.Center, {.Draw_Side_Top}, "###props_actions") {
		ui.space(ui.SPACE_4)
		if p != nil && !pp.gone {
			if ui.tags("weak") {
				ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###prio_label", i18n.tr("Priority")))
			}
			ui.space(ui.CONTROL_GAP)
			names: [len(PRIORITIES)]string
			for q, i in PRIORITIES { names[i] = i18n.tr(q.name) }
			if !ui.menu_any_open() { pp.nice_sel = priority_index(p.nice) }
			ui.next({width = ui.px(em * 10), height = ui.px(ui.dense(em * 2.1))})
			if ui.dropdown("###priority", names[:], &pp.nice_sel) { set_priority(app, p, PRIORITIES[pp.nice_sel].nice) }
			ui.space(ui.CONTROL_GAP)
			if props_button(app, "props_affinity", lucide.MICROCHIP, i18n.tr("Affinity…"), .Props_Affinity, em) { cmd_run(app, .Props_Affinity) }
			ui.space(ui.CONTROL_GAP)
			eco_lbl := p.extra.efficiency ? i18n.tr("EcoQoS: On") : i18n.tr("EcoQoS")
			if props_button(app, "props_eco", lucide.LEAF, eco_lbl, .Props_Efficiency, em) { efficiency_toggle(app, p) }
			ui.space(ui.SPACE_2)
			if ui.tags("weak") {
				msg := ui.now_ms() < app.status_until ? app.status : ""
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, font_size = em * 0.9})
				ui.label_tip(fmt.tprintf("%s###props_msg", ui.text_shown(msg)))
			}
			stopped := p.state == .Stopped
			if props_button(app, "props_suspend", stopped ? lucide.PLAY : lucide.SQUARE, stopped ? i18n.tr("Resume") : i18n.tr("Suspend"), .Props_Suspend, em, .Primary) { props_suspend(app) }
			ui.space(ui.CONTROL_GAP)
			if props_button(app, "props_end", lucide.X, i18n.tr("End task"), .Props_End_Task, em, .Warning) { props_signal(app, false) }
			ui.space(ui.CONTROL_GAP)
			if props_button(app, "props_kill", lucide.ZAP, i18n.tr("Kill…"), .Props_Kill, em, .Danger) { props_signal(app, true) }
		} else {
			ui.spacer(ui.fill())
		}
		ui.space(ui.SPACE_4)
	}
}

@(private = "file")
props_button :: proc(app: ^App, id, icon, label: string, c: Cmd, em: f32, intent := ui.Intent.Neutral) -> bool {
	sig := ui.button(id, label, icon, {intent = intent, height = ui.dense(em * 2.1), tip = fmt.tprintf("%s (%s)", label, ui.command_shortcut(COMMANDS[c]))})
	ui.act_command(sig.box, COMMANDS[c].id)
	return sig.clicked
}

@(private = "file")
props_keys :: proc(app: ^App) {
	pp := &app.props
	keeps := ui.focus_key() == pp.filter_key && pp.filter_key != 0 && len(pp.filter.buf) > 0
	for c in Cmd {
		if !cmd_is_props(c) || c == .Props_Close { continue }
		if keeps && (c == .Props_End_Task || c == .Props_Kill) { continue }
		if ui.command_pressed(COMMANDS[c], !cmd_can(app, c)) { cmd_run(app, c) }
	}
}

@(private = "file")
props_filter_field :: proc(app: ^App, em: f32) {
	pp := &app.props
	ui.next({width = ui.px(em * 14), height = ui.px(ui.dense(em * 2))})
	res := ui.line_edit("###props_filter", &pp.filter, {placeholder = i18n.tr("Filter the list…")})
	pp.filter_key = res.box.key
	tip_after(res, cmd_tip(.Props_Filter))
	ui.space(ui.SPACE_2)
}

props_filter_focus :: proc(app: ^App) {
	pp := &app.props
	if !props_tab_listed(pp.tab) { pp.tab = .Threads }
	if pp.filter_key != 0 { ui.set_focus(pp.filter_key) }
}

hover_tip :: proc(name, text: string) {
	key := ui.key_from_string(ui.parent_box().key, fmt.tprintf("###%s", name))
	tip_after(ui.Signal{hovering = ui.hot_key() == key}, text)
}

props_suspend :: proc(app: ^App) {
	if p := find_proc(&app.sampler, app.props.pid, app.props.start); p != nil { suspend_or_resume(app, p) }
}

props_signal :: proc(app: ^App, kill: bool) {
	p := find_proc(&app.sampler, app.props.pid, app.props.start)
	if p == nil { return }
	c := Chosen{name = fmt.tprintf(i18n.tr("%s (PID %d)"), p.name, p.pid)}
	append(&c.targets, Target{p.pid, p.start})
	defer delete(c.targets)
	if kill { confirm_ask(app, c, .Kill) } else { signal_or_confirm(app, &c, .Terminate) }
}
