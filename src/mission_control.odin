package inspecteur

// Mission Control: the whole machine on one page, in panels the user arranges: the machine's tiles and graphs, what the
// diagnosis says, the busiest processes by CPU and by memory, the services (the failed ones first), the network's
// sockets, what starts with the session, the system. Each panel is a view ("mission/<panel>": views.odin) docked in the
// section's dock space: its zones (the top, the left, the centre, the right, the bottom) hold stacks of panels, a tab
// each when a stack holds more than one; the lines between them resize them. A panel moves by its menu (a right click at
// its top, or its tab), by a drag of its tab, or by the palette: to another zone or stack, floating in the window, in a
// window of its own, or to an edge of the window. It can be closed and brought back from the panels' menu; Mission
// Control: the layout as at first (the palette, the bar's button) puts each panel back in its place. The views' memory
// keeps the layout, and the panels open at the last quit open again, in a window of their own too. A click on a line
// goes to its section; a right click opens its menu: its section, and what is related to it (a process's properties,
// service and connections; a service's process, details and journal).
//
// It reads nothing of its own: each section's reading (Mission Control asks every section to read while it is shown, or
// while one of its panels is out of it).

import "core:fmt"
import "core:strings"
import "gt:draw"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"
import i18n "gt:i18n"

Mission_Panel :: enum u32 { Machine = 1, Health, Cpu, Memory, Services, Network, Startup, System }

@(rodata)
MISSION_NAMES := [Mission_Panel]string{
	.Machine = "machine", .Health = "health", .Cpu = "cpu", .Memory = "memory",
	.Services = "services", .Network = "network", .Startup = "startup", .System = "system",
}

// Each panel's view.
@(rodata)
MISSION_VIEWS := [Mission_Panel]string{
	.Machine = "mission/machine", .Health = "mission/health", .Cpu = "mission/cpu", .Memory = "mission/memory",
	.Services = "mission/services", .Network = "mission/network", .Startup = "mission/startup", .System = "mission/system",
}

// (not rodata: i18n.later runs when the program starts)
MISSION_TITLES := [Mission_Panel]string{
	.Machine = i18n.later("Machine"), .Health = i18n.later("Health"), .Cpu = i18n.later("Busiest: CPU"), .Memory = i18n.later("Busiest: memory"),
	.Services = i18n.later("Services"), .Network = i18n.later("Network"), .Startup = i18n.later("Startup"), .System = i18n.later("System"),
}

@(rodata)
MISSION_ICONS := [Mission_Panel]string{
	.Machine = lucide.GAUGE, .Health = lucide.LIGHTBULB, .Cpu = lucide.CPU, .Memory = lucide.LAYERS_2,
	.Services = lucide.SETTINGS, .Network = lucide.GLOBE, .Startup = lucide.POWER, .System = lucide.INFO,
}

// The layout at first, each panel's home: the machine across the top; under it the health, the busiest processes by
// CPU and by memory side by side; under them the services, the network, and the startup with the system in tabs.
@(rodata)
MISSION_PLACES := [Mission_Panel]ui.View_Place{
	.Machine  = {space = MISSION_SPACE, edge = .Top},
	.Health   = {space = MISSION_SPACE, edge = .Left},
	.Cpu      = {space = MISSION_SPACE, edge = .Center},
	.Memory   = {space = MISSION_SPACE, edge = .Right},
	.Services = {space = MISSION_SPACE, edge = .Bottom, stack = 0},
	.Network  = {space = MISSION_SPACE, edge = .Bottom, stack = 1},
	.Startup  = {space = MISSION_SPACE, edge = .Bottom, stack = 2},
	.System   = {space = MISSION_SPACE, edge = .Bottom, stack = 2},
}

// The zones at first, as shares of the section (they follow the window): the machine a third of its height at the top,
// the bottom row a third of it; in the row between them, the health a third of the width at the left, the busiest by
// memory a third at the right, the busiest by CPU the rest in the centre. The bottom zone's three stacks share its
// width equally.
@(rodata)
MISSION_ZONES := ui.View_Dock_Options{extent_frac = #partial [ui.View_Edge]f32{.Top = 0.32, .Bottom = 0.34, .Left = 0.34, .Right = 0.33}}

// The order the panels open in at the start and come back in: a stack's tab shown is the last opened (Startup over
// System).
@(rodata)
MISSION_ORDER := [?]Mission_Panel{.Machine, .Health, .Cpu, .Memory, .Services, .Network, .System, .Startup}

// A panel's size floating or in a window of its own, at first (ems).
@(private = "file") MISSION_W_EM :: 46
@(private = "file") MISSION_H_EM :: 30

// The panels' menu's width, in ems: its last line ("Mission Control: the layout as at first") whole.
@(private = "file") MISSION_MENU_EM :: 22
// The lines a list panel shows at most.
@(private = "file") MISSION_TOP :: 8

// The panels' menu, and a line's menu (a right click).
MISSION_MENU :: "inspecteur_mission_panels"
MISSION_LINE_MENU :: "inspecteur_mission_line"

Mission_Control :: struct {
	line:      Mission_Line,
	// the last frame (App.frames) a panel was built out of the section (floating, in a window, docked elsewhere): what
	// Mission Control sums up is read while it is (connections_shown)
	out_frame: int,
}

// What a line shows, for its menu: a process, a service or a startup item.
Mission_Line_Kind :: enum u8 { None, Process, Service, Startup }

Mission_Line :: struct {
	kind:  Mission_Line_Kind,
	pid:   i32,      // Process
	start: u64,      // Process: its identity with the pid
	name:  string,   // owned: Service, Startup
}

mission_init :: proc(app: ^App) {
	app.mission.out_frame = -MISSION_OUT_FRAMES - 1   // (no panel was out yet)
}

mission_destroy :: proc(app: ^App) {
	delete(app.mission.line.name)
}

// A panel built out of the section counts this many frames: a frame of the main window may come without one of a
// panel's window.
MISSION_OUT_FRAMES :: 2

// Once, at start-up, on the program's Views: each panel, its home in the section's dock space.
mission_register :: proc(app: ^App) {
	for p in Mission_Panel {
		ui.view_register(&app.views, MISSION_VIEWS[p], mission_view, ui.View_Options{
			title = MISSION_TITLES[p], icon = MISSION_ICONS[p], home = .Panel, home_place = MISSION_PLACES[p],
			width_em = MISSION_W_EM, height_em = MISSION_H_EM,
		})
	}
}

// At start-up: the panels open at the last quit (each at its very first start), where they were.
mission_restore :: proc(app: ^App) {
	for p in MISSION_ORDER { _ = ui.view_restore(&app.views, MISSION_VIEWS[p], app, first_start_open = true, owner = &app.main.state) }
}

// The panel of the view `id`.
@(private = "file")
mission_panel_of :: proc(id: string) -> Mission_Panel {
	for v, p in MISSION_VIEWS { if v == id { return p } }
	return .Machine
}

// The layout as at first: the zones' and stacks' sizes and the tabs shown back to the defaults, each panel back in its
// place (one floated, in a window or docked elsewhere comes back), those closed open again.
mission_reset :: proc(app: ^App) {
	for p in MISSION_ORDER {
		id := MISSION_VIEWS[p]
		if !ui.view_is_open(&app.views, id) { ui.view_open(&app.views, id, app, owner = &app.main.state) }
	}
	ui.views_space_reset(&app.views, MISSION_SPACE)
	tab_show(app, .Mission_Control)
	say(app, i18n.tr("Mission Control: the layout as at first"))
}

mission_panels_open :: proc(app: ^App) {
	tab_show(app, .Mission_Control)
	ui.menu_open(MISSION_MENU, ui.Vec2{app.bar_rect.max.x - ui.font_size() * 16, app.bar_rect.max.y}, from_keyboard = true)
}

build_mission :: proc(app: ^App, em: f32) {
	shown := 0
	for id in MISSION_VIEWS { if ui.view_is_open(&app.views, id) { shown += 1 } }
	section_bar(app, i18n.tr("Mission Control"), fmt.tprintf(i18n.tr("%d of %d panels: a right click at the top of one moves it"), shown, len(Mission_Panel)), em, nil, mission_bar_right)
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.views_dock(&app.views, MISSION_SPACE, MISSION_ZONES) {}
	mission_menu(app, em)
}

// Each frame (the main window's build): a panel the user closed is said, with where it comes back from.
mission_closed_say :: proc(app: ^App) {
	for id, p in MISSION_VIEWS {
		if code, ok := ui.view_ended(&app.views, id); ok && code == ui.VIEW_CANCELLED {
			say(app, i18n.tr("%s closed: the panels' menu brings it back"), i18n.tr(MISSION_TITLES[p]))
		}
	}
}

// A panel's view: the panel, wherever it is. Out of the section (floating, in a window of its own, docked elsewhere),
// what Mission Control sums up is read; in a window of its own, a line's menu is that window's, and a line clicked
// shows its section in the main window, which comes forward.
@(private = "file")
mission_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	if v.presentation != .Panel || v.place.space != MISSION_SPACE {
		if app.frames - app.mission.out_frame > MISSION_OUT_FRAMES { mission_read(app) }
		app.mission.out_frame = app.frames
	}
	tab := app.tab
	mission_panel(app, mission_panel_of(v.id), em)
	if v.presentation == .External {
		mission_line_menu(app, em)
		if app.tab != tab { platform.raise_window(app.main.win) }
	}
}

// Whether a panel was built out of the section lately.
mission_out :: proc(app: ^App) -> bool { return app.frames - app.mission.out_frame <= MISSION_OUT_FRAMES }

// The bar's right: the panels' menu, the layout as at first.
@(private = "file")
mission_bar_right :: proc(app: ^App, em: f32) {
	if tool_button("mission_panels", lucide.LAYOUT_GRID, cmd_tip(.Mission_Panels), true, em) {
		ui.menu_open(MISSION_MENU, ui.mouse_pos())
	}
	if tool_button("mission_reset", lucide.ROTATE_CCW, cmd_tip(.Mission_Reset), true, em) { mission_reset(app) }
	ui.spacer(ui.px(em * 0.4))
}

// Each panel, shown or not (a click brings a closed one back beside the others, or closes a shown one); the layout as
// at first.
@(private = "file")
mission_menu :: proc(app: ^App, em: f32) {
	if ui.menu(MISSION_MENU, em * MISSION_MENU_EM) {
		ui.menu_heading(i18n.tr("Panels"))
		for p in Mission_Panel {
			id := MISSION_VIEWS[p]
			on := ui.view_is_open(&app.views, id)
			if ui.menu_item(i18n.tr(MISSION_TITLES[p]), checked = on).clicked {
				// (one brought back opens where it was last: the views' memory)
				if on { ui.view_close(&app.views, id) } else { ui.view_open(&app.views, id, app, owner = &app.main.state) }
			}
		}
		ui.menu_separator()
		if ui.menu_item(cmd_label(.Mission_Reset)).clicked { mission_reset(app) }
	}
}

// What Mission Control sums up, read now: each section (when it is shown, or one of its panels is out of it).
mission_read :: proc(app: ^App) {
	connections_ask(app)
	if !app.information.asked { information_ask(&app.information) }
	services_ask(app)
	startup_ask(app)
}

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
		if ui.column(id = "###mc_cpu") { captioned_graph(app, "mc_cpu_graph", i18n.tr("CPU"), {{&m.cpu_hist, hue(app, HUE_CPU), ""}}, 100, percent_top, em, ui.fill()) }
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column(id = "###mc_mem") { captioned_graph(app, "mc_mem_graph", i18n.tr("Memory"), {{&m.mem_hist, hue(app, HUE_MEMORY), ""}}, 100, percent_top, em, ui.fill()) }
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
	word := worst == .Bad ? i18n.tr("Struggling") : worst == .Warn ? i18n.tr("Under strain") : i18n.tr("Healthy")
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
			ui.label(fmt.tprintf("%s###mc_health_cpu", fmt.tprintf(i18n.tr("CPU %s"), percent_text(f64(app.machine.cpu)))))
		}
		ui.spacer(ui.fill())
		// (i): every finding, in its words
		ui.next({width = ui.px(em * 1.8), height = ui.px(em * 1.8), font = app.icons, font_size = em, text_align = .Center, text_pad = 0, cursor = .Help})
		info: ui.Signal
		if ui.tags("weak") { info = ui.signal(ui.build_box({.Clickable, .Draw_Text, .No_Text_Trunc, .Draw_Hot_Effects}, fmt.tprintf("%s###mc_health_info", lucide.INFO))) }
		if info.clicked { diagnosis_open(app) }
		if ui.hovered_for(info) {
			if ui.tooltip() {
				ui.next({width = ui.px(em * 24), height = ui.children_sum(), axis = .Y})
				if ui.column(id = "###mc_health_tip") {
					for f, k in findings {
						ui.next({width = ui.fill()})
						// (a tooltip's: it goes when the pointer moves, so nothing selects in it; the diagnosis has the words)
						if ui.style({text_pad = em * 0.3}) { ui.paragraph(fmt.tprintf("%s %s###f%d", f.level == .Bad ? "●" : f.level == .Warn ? "▲" : "✓", ui.text_shown(f.text), k), selectable = false) }
					}
					if ui.tags("weak") {
						ui.next({width = ui.fill()})
						if ui.style({text_pad = em * 0.3}) { ui.paragraph(fmt.tprintf("%s###more", fmt.tprintf(i18n.tr("A click, or %s: why it is slow, in full."), ui.command_shortcut(COMMANDS[.Diagnose]))), selectable = false) }
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
	// (ranked at the sample: ranking_make)
	order := app.ranking.busiest[memory ? .Memory : .Cpu][:]
	procs := app.sampler.procs[:]
	top := order[:min(len(order), MISSION_TOP)]
	most := f32(1)
	if len(top) > 0 { most = memory ? max(f32(procs[top[0]].private), 1) : max(procs[top[0]].cpu, 1) }
	for i, k in top {
		p := procs[i]
		value := memory ? size_text(p.private) : percent_text(f64(p.cpu), 1)
		share := memory ? f32(p.private) / most : p.cpu / most
		if mission_line(app, fmt.tprintf("mc_%s_%d", memory ? "mem" : "cpu", k), p.name, fmt.tprintf(i18n.tr("PID %d"), p.pid), value, share, "", em, {kind = .Process, pid = p.pid, start = p.start}) {
			processes_reveal(app, p.pid, p.start)
		}
	}
}

// The services: how many run, how many failed; the failed ones by name (a click selects it in Services).
@(private = "file")
mission_services :: proc(app: ^App, em: f32) {
	s := &app.services
	if s.list == nil || s.list.manager != s.manager { mission_note(i18n.tr("Reading…"), em); return }
	if s.list.problem != "" { mission_note(s.list.problem, em); return }
	// (counted when the list was read: services_take)
	failed := s.list.failed
	n := len(s.list.units)
	mission_note(fmt.tprintf(s.manager == .System ? i18n.tr(n, "%d service of the system: %d running, %d failed", "%d services of the system: %d running, %d failed") : i18n.tr(n, "%d service of the user: %d running, %d failed", "%d services of the user: %d running, %d failed"), n, s.list.running, failed), em)
	k := 0
	for u in s.list.units {
		if k >= failed { break }
		if u.active != "failed" { continue }
		if mission_line(app, fmt.tprintf("mc_svc_%d", k), u.name, u.description, unit_word("failed"), -1, "bad", em, {kind = .Service, name = u.name}) {
			mission_show_service(app, u.name)
		}
		k += 1
		if k >= MISSION_TOP { break }
	}
	if failed == 0 { mission_note(i18n.tr("No service failed."), em) }
}

// The network: its rate, the sockets that listen and those connected; the processes with the most sockets.
@(private = "file")
mission_network :: proc(app: ^App, em: f32) {
	m := &app.machine
	c := &app.connections
	// (counted when the sockets were read: connections_count)
	mission_note(fmt.tprintf(i18n.tr("%s now; %d listening, %d connected"), bits_text(m.net_rate), c.listening, c.connected), em)
	list := c.holders[:]
	most := len(list) > 0 ? f32(list[0].n) : 1
	for h, k in list[:min(len(list), MISSION_TOP)] {
		name := fmt.tprintf(i18n.tr("PID %d"), h.pid)
		// (by its pid alone: a socket's process often comes with no start time)
		start := h.start
		if q := find_pid(&app.sampler, h.pid); q != nil && !q.ended { name, start = q.name, q.start }
		if mission_line(app, fmt.tprintf("mc_net_%d", k), name, fmt.tprintf(i18n.tr("PID %d"), h.pid), fmt.tprintf(i18n.tr(h.n, "%d socket", "%d sockets"), h.n), f32(h.n) / most, "", em, {kind = .Process, pid = h.pid, start = start}) {
			mission_show_connections(app, h.pid)
		}
	}
}

// What starts with the session: how many items, how many on; those on by name.
@(private = "file")
mission_startup :: proc(app: ^App, em: f32) {
	s := &app.startup
	if s.list == nil { mission_note(i18n.tr("Reading…"), em); return }
	// (counted when the list was read: startup_posted)
	on := s.list.on_count
	mission_note(fmt.tprintf(i18n.tr(len(s.list.items), "%d item, %d on", "%d items, %d on"), len(s.list.items), on), em)
	k := 0
	for it in s.list.items {
		if k >= on { break }
		if !it.enabled { continue }
		if mission_line(app, fmt.tprintf("mc_start_%d", k), it.name, it.command, it.status, -1, "", em, {kind = .Startup, name = it.name}) { tab_show(app, .Startup) }
		k += 1
		if k >= MISSION_TOP { break }
	}
}

// The system: its name, its operating system and kernel, its processor, its memory, its GPUs, how long it has run.
@(private = "file")
mission_system :: proc(app: ^App, em: f32) {
	m := &app.machine
	info := app.information.data
	if info == nil { mission_note(i18n.tr("Reading…"), em); return }
	facts := [][2]string{
		{i18n.tr("Computer"), info.hostname},
		{i18n.tr("System"), fmt.tprintf(i18n.tr("%s, kernel %s"), info.os_name, info.kernel)},
		{i18n.tr("Processor"), info.cpu.model},
		{i18n.tr("Memory"), size_text(m.mem.total)},
		{i18n.tr("Up for"), uptime_text(m.uptime)},
		{i18n.tr("Desktop"), info.desktop},
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
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, flags = {.Selectable}})   // (content: a fact to copy)
			ui.label_tip(fmt.tprintf("%s###v", ui.text_shown(f[1])))
		}
	}
	for g, i in info.gpus {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.7)), axis = .X, cross = .Center})
		if ui.row(.Center, {}, fmt.tprintf("###mc_gpu_%d", i)) {
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") {
				ui.next({width = ui.px(em * 7), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###k", fmt.tprintf(i18n.tr("GPU %d"), i)))
			}
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, flags = {.Selectable}})
			ui.label_tip(fmt.tprintf("%s###v", ui.text_shown(g.name)))
		}
	}
	if mission_more(app, "mc_system_more", i18n.tr("Information"), em) { tab_show(app, .Information) }
}

// A line of a list panel: its name, a faint detail, its value at the right, a bar of its share (-1: none), in the
// colour of `tag`. True when clicked anywhere on it; a right click opens the menu of what it shows (`line`, its name
// not kept: it is cloned when the menu opens). Its texts are plain labels: a clickable label would take the click.
// The panel's width, from which a line keeps less: under MISSION_FULL_EM no detail, under MISSION_BAR_EM no bar either.
// The value is never cut; the name is, with an ellipsis, and its tooltip says it whole.
@(private = "file") MISSION_FULL_EM :: 26
@(private = "file") MISSION_BAR_EM :: 17

@(private = "file")
mission_line :: proc(app: ^App, id, name, detail, value: string, share: f32, tag: string, em: f32, line: Mission_Line) -> bool {
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.9)), axis = .X, cross = .Center})
	ui.push_tags("list_row")
	b := ui.build_box({.Clickable, .Draw_Hot_Effects, .Hot_Within}, fmt.tprintf("###%s", id))
	ui.pop_tags()
	b.cursor = .Hand
	sig := ui.signal(b)
	// (the row's width at the last layout: 0 at its first build, shown whole then)
	wide := b.size.x <= 0 || b.size.x >= em * MISSION_FULL_EM
	bar := b.size.x <= 0 || b.size.x >= em * MISSION_BAR_EM
	if sig.right_clicked { mission_line_menu_open(app, line, ui.mouse_pos()) }
	if ui.parent(b) {
		ui.spacer(ui.px(em * 0.8))
		if tag != "" { ui.push_tags(tag) }
		ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
		n := ui.label(fmt.tprintf("%s###n", ui.text_shown(name)))
		if tag != "" { ui.pop_tags() }
		d: ui.Signal
		if detail != "" && wide {
			if ui.tags("weak") {
				ui.spacer(ui.px(em * 0.5))
				ui.next({width = ui.px(em * 6), height = ui.pct(1), text_pad = 0, font_size = em * 0.9})
				d = ui.label(fmt.tprintf("%s###d", ui.text_shown(detail)))
			}
		}
		// the row's tooltip: what its line cuts, whole
		if text_cut(n.box, name) || d.box != nil && text_cut(d.box, detail) || !wide && detail != "" {
			tip_after(sig, detail == "" ? name : fmt.tprintf("%s, %s", name, detail))
		}
		if share >= 0 && bar {
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.px(em * 4.5), height = ui.px(em * 0.5)})
			ui.meter_bar("###bar", clamp(share, 0, 1))
		}
		// (the value as wide as its text: never cut)
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
		ui.label(fmt.tprintf("%s###v", value))
		ui.spacer(ui.px(em * 0.8))
	}
	return sig.clicked
}

// A line's menu, opened at `pos` on what it shows.
@(private = "file")
mission_line_menu_open :: proc(app: ^App, line: Mission_Line, pos: ui.Vec2) {
	mc := &app.mission
	delete(mc.line.name)
	mc.line = line
	mc.line.name = strings.clone(line.name)
	ui.menu_open(MISSION_LINE_MENU, pos)
}

// The menu of a line: its section first, then what is related to it. The process is found again by its pid and start
// time (gone: the menu closes); the service and the startup item by their names in their sections.
mission_line_menu :: proc(app: ^App, em: f32) {
	mc := &app.mission
	if ui.menu(MISSION_LINE_MENU, em * 16) {
		line := mc.line
		switch line.kind {
		case .None:
			ui.menu_close()
		case .Process:
			p := find_proc(&app.sampler, line.pid, line.start)
			if p == nil { ui.menu_close(); return }
			if ui.menu_item(i18n.tr("Show in Processes"), icon = lucide.LAYOUT_LIST, icon_font = app.icons).clicked { processes_reveal(app, p.pid, p.start) }
			if ui.menu_item(cmd_label(.Properties), icon = COMMANDS[.Properties].icon, icon_font = app.icons).clicked {
				props_open(app, p.pid, p.start)
			}
			ui.menu_separator()
			if ui.menu_item(cmd_label(.Go_To_Service), icon = COMMANDS[.Go_To_Service].icon, disabled = p.unit == "", icon_font = app.icons).clicked { go_to_service(app, p) }
			if ui.menu_item(i18n.tr("Show its connections"), icon = lucide.GLOBE, icon_font = app.icons).clicked { mission_show_connections(app, p.pid) }
			ui.menu_separator()
			if ui.menu_item(cmd_label(.Open_Location), icon = COMMANDS[.Open_Location].icon, disabled = p.exe == "", icon_font = app.icons).clicked { open_location(app, p) }
			if ui.menu_item(cmd_label(.Copy_Command), icon = COMMANDS[.Copy_Command].icon, disabled = p.cmdline == "", icon_font = app.icons).clicked { copy_command(app, p) }
		case .Service:
			u, found := mission_service(app, line.name)
			if !found { ui.menu_close(); return }
			if ui.menu_item(i18n.tr("Show in Services"), icon = lucide.SETTINGS, icon_font = app.icons).clicked { mission_show_service(app, line.name) }
			q := u.pid > 0 ? find_pid(&app.sampler, u.pid) : nil
			if ui.menu_item(i18n.tr("Show its process"), icon = lucide.LAYOUT_LIST, disabled = q == nil, icon_font = app.icons).clicked { processes_reveal(app, q.pid, q.start) }
			if ui.menu_item(cmd_label(.Service_Details), icon = COMMANDS[.Service_Details].icon, icon_font = app.icons).clicked {
				mission_show_service(app, line.name)
				if !service_details_shown(app) { service_details_switch(app) }
			}
		case .Startup:
			if ui.menu_item(i18n.tr("Show in Startup"), icon = lucide.POWER, icon_font = app.icons).clicked { tab_show(app, .Startup) }
		}
	}
}

// A service of the list shown, by its name.
@(private = "file")
mission_service :: proc(app: ^App, name: string) -> (Service, bool) {
	s := &app.services
	if s.list == nil { return {}, false }
	for u in s.list.units { if u.name == name { return u, true } }
	return {}, false
}

// Services, the service selected (once a reading lists it).
@(private = "file")
mission_show_service :: proc(app: ^App, name: string) {
	tab_show(app, .Services)
	service_select(app, name)
}

// Connections, filtered on the process's pid.
@(private = "file")
mission_show_connections :: proc(app: ^App, pid: i32) {
	tab_show(app, .Connections)
	ui.line_edit_set(&app.search, fmt.tprintf("%d", pid))
}

@(private = "file")
mission_note :: proc(text: string, em: f32) {
	if ui.tags("weak") {
		// (its height: its lines'; a paragraph has no children to sum)
		ui.next({width = ui.fill(), text_pad = em * 0.8})
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
