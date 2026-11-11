package inspecteur

// Mission Control: the whole machine on one page, in panels the user arranges (gui_toolkit's dock, its docs/docking.md):
// the machine's tiles and graphs, what the diagnosis says, the busiest processes by CPU and by memory, the services (the
// failed ones first), the network's sockets, what starts with the session, the system. Each panel is a tab that can be
// dragged into another stack, beside one, to an edge, or out to float; the line between two stacks resizes them; a
// panel can be closed and brought back from the panels' menu; Mission Control: the layout as at first (the palette, the
// bar's button) sets it back. The layout is kept (mission.layout). A click on a line goes to its section.
//
// It reads nothing of its own: each section's reading (Mission Control asks every section to read while it is shown).

import "core:fmt"
import "core:slice"
import "core:strings"
import "gt:draw"
import lucide "gt:lucide"
import "gt:ui"

Mission_Panel :: enum u32 { Machine = 1, Health, Cpu, Memory, Services, Network, Startup, System }

@(rodata)
MISSION_NAMES := [Mission_Panel]string{
	.Machine = "machine", .Health = "health", .Cpu = "cpu", .Memory = "memory",
	.Services = "services", .Network = "network", .Startup = "startup", .System = "system",
}

@(rodata)
MISSION_TITLES := [Mission_Panel]string{
	.Machine = "Machine", .Health = "Health", .Cpu = "Busiest: CPU", .Memory = "Busiest: memory",
	.Services = "Services", .Network = "Network", .Startup = "Startup", .System = "System",
}

// The layout at first: the machine across the top; under it the health and the busiest processes; under them the
// services, the network, and the startup with the system in tabs.
MISSION_DEFAULT :: "dock1 y0.320([*machine] y0.500(x0.340([*health] x0.500([*cpu] [*memory])) x0.340([*services] x0.500([*network] [*startup,system]))))"

// The lines a list panel shows at most.
@(private = "file") MISSION_TOP :: 8

Mission_Control :: struct {
	dock: ui.Dock,
	menu: ui.Key,   // the panels' menu
}

mission_init :: proc(app: ^App) {
	ui.dock_init(&app.mission.dock)
	if !ui.dock_parse(&app.mission.dock, app.settings.mission_layout, mission_id_of, app) {
		ui.dock_parse(&app.mission.dock, MISSION_DEFAULT, mission_id_of, app)
	}
}

mission_destroy :: proc(app: ^App) { ui.dock_destroy(&app.mission.dock) }

@(private = "file")
mission_id_of :: proc(user: rawptr, name: string) -> (u32, bool) {
	for n, p in MISSION_NAMES { if n == name { return u32(p), true } }
	return 0, false
}

@(private = "file")
mission_name :: proc(user: rawptr, id: u32) -> string {
	if id < u32(min(Mission_Panel)) || id > u32(max(Mission_Panel)) { return "" }
	return MISSION_NAMES[Mission_Panel(id)]
}

@(private = "file")
mission_save :: proc(user: rawptr, d: ^ui.Dock) {
	app := (^App)(user)
	text := ui.dock_format(d, mission_name, app)
	pref_save(&app.prefs, "mission.layout", text)
	delete(app.settings.mission_layout)
	app.settings.mission_layout = strings.clone(text)
}

// The layout as at first, kept.
mission_reset :: proc(app: ^App) {
	ui.dock_parse(&app.mission.dock, MISSION_DEFAULT, mission_id_of, app)
	mission_save(app, &app.mission.dock)
	tab_show(app, .Mission_Control)
	say(app, "Mission Control: the layout as at first")
}

mission_panels_open :: proc(app: ^App) {
	tab_show(app, .Mission_Control)
	if app.mission.menu == 0 { app.mission.menu = ui.key_from_string(0, "inspecteur_mission_panels") }
	ui.ctx_menu_open(app.mission.menu, {app.bar_rect.max.x - ui.font_size() * 16, app.bar_rect.max.y}, from_keyboard = true)
}

build_mission :: proc(app: ^App, em: f32) {
	d := &app.mission.dock
	shown := 0
	for p in Mission_Panel { if ui.dock_has(d, u32(p)) { shown += 1 } }
	section_bar(app, "Mission Control", fmt.tprintf("%d of %d panels: drag a tab to move it", shown, len(Mission_Panel)), em, nil, mission_bar_right)
	ui.next({width = ui.fill(), height = ui.fill()})
	ui.dock_begin(d, "###mission", {
		title = proc(user: rawptr, panel: u32) -> string { return MISSION_TITLES[Mission_Panel(panel)] },
		on_save = mission_save, user = app, close_buttons = true,
	})
	for p in Mission_Panel {
		if ui.dock_panel(d, u32(p)) { mission_panel(app, p, em) }
	}
	res := ui.dock_end(d)
	if res.closed != ui.DOCK_NO_PANEL { say(app, "%s closed: the panels' menu brings it back", MISSION_TITLES[Mission_Panel(res.closed)]) }
	mission_menu(app, em)
}

// The bar's right: the panels' menu, the layout as at first.
@(private = "file")
mission_bar_right :: proc(app: ^App, em: f32) {
	if app.mission.menu == 0 { app.mission.menu = ui.key_from_string(0, "inspecteur_mission_panels") }
	if tool_button(app, "mission_panels", lucide.LAYOUT_GRID, cmd_tip(.Mission_Panels), true, em) {
		ui.ctx_menu_open(app.mission.menu, ui.mouse_pos())
	}
	if tool_button(app, "mission_reset", lucide.ROTATE_CCW, cmd_tip(.Mission_Reset), true, em) { mission_reset(app) }
	ui.spacer(ui.px(em * 0.4))
}

// Each panel, shown or not (a click brings a closed one back beside the others, or closes a shown one); the layout as
// at first.
@(private = "file")
mission_menu :: proc(app: ^App, em: f32) {
	if app.mission.menu == 0 { return }
	d := &app.mission.dock
	if ui.ctx_menu(app.mission.menu, em * 16) {
		ui.menu_heading("Panels")
		for p in Mission_Panel {
			on := ui.dock_has(d, u32(p))
			if ui.menu_item(MISSION_TITLES[p], checked = on).clicked {
				if on {
					ui.dock_close(d, u32(p))
				} else {
					ui.dock_add(d, u32(p), mission_place(d))
					ui.dock_activate(d, u32(p))
				}
				mission_save(app, d)
			}
		}
		ui.menu_separator()
		if ui.menu_item(COMMANDS[.Mission_Reset].label).clicked { mission_reset(app) }
	}
}

// Where a panel brought back goes: with the first panel shown (else the empty space).
@(private = "file")
mission_place :: proc(d: ^ui.Dock) -> ui.Dock_Target {
	for p in Mission_Panel { if ui.dock_has(d, u32(p)) { return ui.dock_with(d, u32(p)) } }
	return {place = .Tab, node = d.main, index = -1}
}

@(private = "file")
mission_panel :: proc(app: ^App, p: Mission_Panel, em: f32) {
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = surface("well")})
	body := ui.build_box({.Draw_Background, .Clip, .View_Scroll_Y, .View_Clamp_Y}, fmt.tprintf("###mc_%s", MISSION_NAMES[p]))
	// (the body is the parent for the block's length: `if !ui.parent(...) { return }` would let it go at once)
	if ui.parent(body) {
		ui.spacer(ui.px(em * 0.4))
		switch p {
		case .Machine:  mission_machine(app, em)
		case .Health:   mission_health(app, em)
		case .Cpu:      mission_busiest(app, em, false)
		case .Memory:   mission_busiest(app, em, true)
		case .Services: mission_services(app, em)
		case .Network:  mission_network(app, em)
		case .Startup:  mission_startup(app, em)
		case .System:   mission_system(app, em)
		}
	}
}

// The tiles of the machine (the Processes section's summary), then the CPU's and the memory's last minute.
@(private = "file")
mission_machine :: proc(app: ^App, em: f32) {
	m := &app.machine
	summary_build(app, em)
	ui.next({width = ui.fill(), height = ui.px(em * 9), axis = .X})
	if ui.row(id = "###mc_graphs") {
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column(id = "###mc_cpu") { captioned_graph(app, "mc_cpu_graph", "CPU", {{&m.cpu_hist, hue(app, HUE_CPU), ""}}, 100, percent_top, em, ui.fill()) }
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column(id = "###mc_mem") { captioned_graph(app, "mc_mem_graph", "Memory", {{&m.mem_hist, hue(app, HUE_MEMORY), ""}}, 100, percent_top, em, ui.fill()) }
		ui.spacer(ui.px(em * 0.8))
	}
	ui.spacer(ui.px(em * 0.4))
}

// The machine's pulse: a word for the state the diagnosis finds, in its colour; the (i) whose tooltip says each finding;
// a trace as a heart monitor's, a beat per sample of the CPU, as high as the processors were busy, the newest at the
// right. It moves with the samples: no frame between two.
@(private = "file")
mission_health :: proc(app: ^App, em: f32) {
	findings := diagnose(app)
	worst := Finding_Level.Fine
	for f in findings { worst = max(worst, f.level) }
	tag := worst == .Bad ? "bad" : worst == .Warn ? "warn" : "good"
	word := worst == .Bad ? "Struggling" : worst == .Warn ? "Under strain" : "Healthy"
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2)), axis = .X, cross = .Center})
	if ui.row(.Center, {}, "###mc_health_head") {
		ui.spacer(ui.px(em * 0.8))
		if ui.tags(tag) {
			ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0, font_size = em * 1.25})
			ui.label(fmt.tprintf("%s###mc_health_word", word))
		}
		ui.spacer(ui.px(em * 0.6))
		if ui.tags("weak") {
			ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
			ui.label(fmt.tprintf("CPU %.0f%%###mc_health_cpu", app.machine.cpu))
		}
		ui.spacer(ui.fill())
		// (i): every finding, in its words
		ui.next({width = ui.px(em * 1.8), height = ui.px(em * 1.8), font = app.icons, font_size = em, text_align = .Center, text_pad = 0, cursor = .Help})
		info: ui.Signal
		if ui.tags("weak") { info = ui.signal(ui.build_box({.Clickable, .Draw_Text, .No_Text_Trunc, .Draw_Hot_Effects}, fmt.tprintf("%s###mc_health_info", lucide.INFO))) }
		if info.clicked { app.diagnosis_open = true }
		if ui.hovered_for(info, TIP_DELAY_S) {
			if ui.tooltip() {
				ui.next({width = ui.px(em * 24), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###mc_health_tip") {
					for f, k in findings {
						ui.next({width = ui.fill()})
						if ui.style({text_pad = em * 0.3}) { ui.paragraph(fmt.tprintf("%s %s###f%d", f.level == .Bad ? "●" : f.level == .Warn ? "▲" : "✓", ui.text_shown(f.text), k)) }
					}
					if ui.tags("weak") {
						ui.next({width = ui.fill()})
						if ui.style({text_pad = em * 0.3}) { ui.paragraph(fmt.tprintf("A click, or %s: why it is slow, in full.###more", ui.command_shortcut(COMMANDS[.Diagnose]))) }
					}
				}
			}
		}
		ui.spacer(ui.px(em * 0.4))
	}
	d := ui.frame_new(Pulse_Draw)
	d.values = ui.value_history_values(&app.machine.cpu_hist, ui.frame_allocator())
	if ui.tags(tag) { d.color = ui.color("text") }
	d.grid = ui.color("border")
	d.scale, d.em = ui.scale(), em
	ui.next({width = ui.fill(), height = ui.fill()})
	ui.custom("###mc_pulse", pulse_draw, d)
}

@(private = "file")
Pulse_Draw :: struct { values: []f32, color, grid: ui.Color, scale, em: f32 }

// One beat, as a heart monitor draws it: x along the beat (0..1), y as a share of the spike's height (up is positive).
@(private = "file", rodata)
PULSE_BEAT := [?][2]f32{{0, 0}, {0.28, 0}, {0.33, 0.09}, {0.38, 0}, {0.42, -0.10}, {0.46, 1}, {0.50, -0.30}, {0.55, 0}, {0.66, 0.16}, {0.75, 0}, {1, 0}}

// A beat's width, in ems: the trace shows as many as fit.
@(private = "file") PULSE_BEAT_EM :: 3.6

@(private = "file")
pulse_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Pulse_Draw)(user)
	r := b.rect
	w, h := r.max.x - r.min.x, r.max.y - r.min.y
	if w < 4 || h < 4 { return }
	p := max(1, d.scale)
	// (a faint grid, as on the monitor's glass)
	g := d.grid
	g.a *= 0.35
	for k in 1 ..< 4 { draw.rect(dc, {{r.min.x, r.min.y + h * f32(k) / 4}, {r.max.x, r.min.y + h * f32(k) / 4 + p}}, g) }
	beat := d.em * PULSE_BEAT_EM
	n := min(len(d.values), int(w / beat) + 1)
	if n == 0 { return }
	values := d.values[len(d.values) - n:]
	base := r.min.y + h * 0.68
	room := h * 0.6
	pts := make([dynamic]draw.Vec2, 0, n * len(PULSE_BEAT), context.temp_allocator)
	for v, i in values {
		x0 := r.max.x - f32(n - i) * beat
		amp := room * (0.18 + 0.82 * clamp(v / 100, 0, 1))
		for q in PULSE_BEAT { append(&pts, draw.Vec2{x0 + q[0] * beat, base - q[1] * amp}) }
	}
	// (the older beats fade: the trace is drawn in pieces, the newest brightest; a soft glow under the line)
	pieces :: 4
	per := max(len(pts) / pieces, 2)
	for k in 0 ..< pieces {
		lo := k * per
		hi := k == pieces - 1 ? len(pts) : min((k + 1) * per + 1, len(pts))
		if hi - lo < 2 { continue }
		c := d.color
		c.a *= 0.35 + 0.65 * f32(k + 1) / pieces
		glow := c
		glow.a *= 0.25
		draw.polyline(dc, pts[lo:hi], 3.5 * p, glow)
		draw.polyline(dc, pts[lo:hi], 1.8 * p, c)
	}
	// the newest point: a bright dot, where the trace is written
	last := pts[len(pts) - 1]
	draw.rect(dc, {last - 3 * p, last + 3 * p}, d.color, 3 * p)
}

// The processes that use the most CPU (or private memory), each with its share as a bar; a click shows it in Processes.
@(private = "file")
mission_busiest :: proc(app: ^App, em: f32, memory: bool) {
	order := make([dynamic]int, 0, len(app.sampler.procs), context.temp_allocator)
	for p, i in app.sampler.procs { if !p.ended { append(&order, i) } }
	procs := app.sampler.procs[:]
	if memory {
		slice.sort_by(order[:], proc(a, b: int) -> bool { return the_app.sampler.procs[a].private > the_app.sampler.procs[b].private })
	} else {
		slice.sort_by(order[:], proc(a, b: int) -> bool { return the_app.sampler.procs[a].cpu > the_app.sampler.procs[b].cpu })
	}
	top := order[:min(len(order), MISSION_TOP)]
	most := f32(1)
	if len(top) > 0 { most = memory ? max(f32(procs[top[0]].private), 1) : max(procs[top[0]].cpu, 1) }
	for i, k in top {
		p := procs[i]
		value := memory ? size_text(p.private) : fmt.tprintf("%.1f%%", p.cpu)
		share := memory ? f32(p.private) / most : p.cpu / most
		if mission_line(app, fmt.tprintf("mc_%s_%d", memory ? "mem" : "cpu", k), p.name, fmt.tprintf("PID %d", p.pid), value, share, "", em) {
			processes_reveal(app, p.pid, p.start)
		}
	}
}

// The services: how many run, how many failed; the failed ones by name (a click selects it in Services).
@(private = "file")
mission_services :: proc(app: ^App, em: f32) {
	s := &app.services
	if s.list == nil || s.list.manager != s.manager { mission_note("Reading…", em); return }
	if s.list.problem != "" { mission_note(s.list.problem, em); return }
	running, failed := 0, 0
	for u in s.list.units {
		if u.active == "active" && u.sub == "running" { running += 1 }
		if u.active == "failed" { failed += 1 }
	}
	mission_note(fmt.tprintf("%s of the %s: %d running, %d failed", count_text(len(s.list.units), "service", "services"), s.manager == .System ? "system" : "user", running, failed), em)
	k := 0
	for u in s.list.units {
		if u.active != "failed" { continue }
		if mission_line(app, fmt.tprintf("mc_svc_%d", k), u.name, u.description, "failed", -1, "bad", em) {
			delete(s.select_name)
			s.select_name = strings.clone(u.name)
			tab_show(app, .Services)
		}
		k += 1
		if k >= MISSION_TOP { break }
	}
	if failed == 0 { mission_note("No service failed.", em) }
}

// The network: its rate, the sockets that listen and those connected; the processes with the most sockets.
@(private = "file")
mission_network :: proc(app: ^App, em: f32) {
	m := &app.machine
	c := &app.connections
	listening, connected := 0, 0
	Holder :: struct { pid: i32, start: u64, n: int }
	holders := make(map[i32]Holder, 16, context.temp_allocator)
	for so in c.sockets {
		if so.state == .Listening { listening += 1 } else if so.state == .Established { connected += 1 }
		if so.pid > 0 {
			h := holders[so.pid]
			h.pid, h.start, h.n = so.pid, so.start, h.n + 1
			holders[so.pid] = h
		}
	}
	mission_note(fmt.tprintf("%s now; %d listening, %d connected", bits_text(m.net_rate), listening, connected), em)
	list := make([dynamic]Holder, 0, len(holders), context.temp_allocator)
	for _, h in holders { append(&list, h) }
	slice.sort_by(list[:], proc(a, b: Holder) -> bool { return a.n > b.n })
	most := len(list) > 0 ? f32(list[0].n) : 1
	for h, k in list[:min(len(list), MISSION_TOP)] {
		name := fmt.tprintf("PID %d", h.pid)
		if p := find_proc(&app.sampler, h.pid, h.start); p != nil { name = p.name }
		if mission_line(app, fmt.tprintf("mc_net_%d", k), name, fmt.tprintf("PID %d", h.pid), count_text(h.n, "socket", "sockets"), f32(h.n) / most, "", em) {
			tab_show(app, .Connections)
		}
	}
}

// What starts with the session: how many items, how many on; those on by name.
@(private = "file")
mission_startup :: proc(app: ^App, em: f32) {
	s := &app.startup
	if s.list == nil { mission_note("Reading…", em); return }
	on := 0
	for it in s.list.items { if it.enabled { on += 1 } }
	mission_note(fmt.tprintf("%s, %d on", count_text(len(s.list.items), "item", "items"), on), em)
	k := 0
	for it in s.list.items {
		if !it.enabled { continue }
		if mission_line(app, fmt.tprintf("mc_start_%d", k), it.name, it.command, it.status, -1, "", em) { tab_show(app, .Startup) }
		k += 1
		if k >= MISSION_TOP { break }
	}
}

// The system: its name, its operating system and kernel, its processor, its memory, its GPUs, how long it has run.
@(private = "file")
mission_system :: proc(app: ^App, em: f32) {
	m := &app.machine
	info := app.information.data
	if info == nil { mission_note("Reading…", em); return }
	facts := [][2]string{
		{"Computer", info.hostname},
		{"System", fmt.tprintf("%s, kernel %s", info.os_name, info.kernel)},
		{"Processor", info.cpu.model},
		{"Memory", size_text(m.mem.total)},
		{"Up for", uptime_text(m.uptime)},
		{"Desktop", info.desktop},
	}
	for f, i in facts {
		if f[1] == "" { continue }
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.7)), axis = .X, cross = .Center})
		if ui.row(.Center, {}, fmt.tprintf("###mc_sys_%d", i)) {
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") {
				ui.next({width = ui.px(em * 7), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###k", f[0]))
			}
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			label_tip(fmt.tprintf("%s###v", ui.text_shown(f[1])), f[1])
		}
	}
	for g, i in info.gpus {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.7)), axis = .X, cross = .Center})
		if ui.row(.Center, {}, fmt.tprintf("###mc_gpu_%d", i)) {
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") {
				ui.next({width = ui.px(em * 7), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("GPU %d###k", i))
			}
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
			label_tip(fmt.tprintf("%s###v", ui.text_shown(g.name)), g.name)
		}
	}
	if mission_more(app, "mc_system_more", "Information", em) { tab_show(app, .Information) }
}

// A line of a list panel: its name, a faint detail, its value at the right, a bar of its share (-1: none), in the
// colour of `tag`. True when clicked.
@(private = "file")
mission_line :: proc(app: ^App, id, name, detail, value: string, share: f32, tag: string, em: f32) -> bool {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.9)), axis = .X, cross = .Center})
	ui.push_tags("list_row")
	b := ui.build_box({.Clickable, .Draw_Hot_Effects, .Hot_Within}, fmt.tprintf("###%s", id))
	ui.pop_tags()
	b.cursor = .Hand
	sig := ui.signal(b)
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.8))
		if tag != "" { ui.push_tags(tag) }
		ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
		label_tip(fmt.tprintf("%s###n", ui.text_shown(name)), name)
		if tag != "" { ui.pop_tags() }
		if detail != "" {
			if ui.tags("weak") {
				ui.next({width = ui.px(em * 6.5), height = ui.pct(1), text_pad = 0, font_size = em * 0.9})
				label_tip(fmt.tprintf("%s###d", ui.text_shown(detail)), detail)
			}
		}
		if share >= 0 {
			ui.next({width = ui.px(em * 5), height = ui.px(em * 0.5)})
			ui.meter_bar("###bar", clamp(share, 0, 1))
			ui.spacer(ui.px(em * 0.6))
		}
		ui.next({width = ui.px(em * 6), height = ui.pct(1), text_pad = 0, text_align = .Right})
		ui.label(fmt.tprintf("%s###v", value))
		ui.spacer(ui.px(em * 0.8))
	}
	return sig.clicked
}

@(private = "file")
mission_note :: proc(text: string, em: f32) {
	if ui.tags("weak") {
		ui.next({width = ui.fill(), height = ui.children_sum(), text_pad = em * 0.8})
		ui.paragraph(fmt.tprintf("%s###mc_note_%s", ui.text_shown(text), ui.text_shown(text)))
	}
}

// A link at a panel's end to its section ("Why is it slow? (F2)").
@(private = "file")
mission_more :: proc(app: ^App, id, text: string, em: f32) -> (clicked: bool) {
	ui.spacer(ui.px(em * 0.3))
	ui.next({width = ui.fill(), height = ui.px(em * 1.8), axis = .X, cross = .Center})
	if ui.row(.Center, {}, fmt.tprintf("###%s_row", id)) {
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0, cursor = .Hand, fg = ui.color("link")})
		clicked = ui.signal(ui.build_box({.Clickable, .Draw_Text}, fmt.tprintf("%s →###%s", text, id))).clicked
	}
	return
}
