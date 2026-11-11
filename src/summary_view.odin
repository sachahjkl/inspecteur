package inspecteur

// The summary at the top of the Processes section (processes.summary, Ctrl+B): the machine on one line, a tile per
// device (CPU, memory, disks, network, the first GPU, the processor's temperature, the pressure), each its value, a
// sparkline of its last minute and a stripe in the colour of its load. A click on a tile shows its device in the
// Performance section. It reads nothing: the sample's numbers (machine.odin).

import "core:fmt"
import "gt:ui"

SUMMARY_EM       :: 3.0   // its height
// The temperature at which a tile's stripe is green, and red (degrees Celsius); the pressure at which it is red.
SUMMARY_TEMP_COOL, SUMMARY_TEMP_HOT :: 45, 95
SUMMARY_PRESSURE_FULL :: 25

@(private = "file")
Tile :: struct {
	id, title, value: string,
	series:  []Series,
	top, floor: f32,
	load:    f32,       // 0 to 1: the stripe's colour (heat_hue); < 0: the accent's
	device:  Device,
}

summary_build :: proc(app: ^App, em: f32) {
	m := &app.machine
	tiles := make([dynamic]Tile, context.temp_allocator)
	mem := m.mem.total > 0 ? f32(f64(mem_used(m)) / f64(m.mem.total)) : 0
	append(&tiles, Tile{"cpu", "CPU", fmt.tprintf("%.0f%%", m.cpu), {{&m.cpu_hist, hue(app, HUE_CPU), ""}}, 100, 0, m.cpu / 100, {.Cpu, 0}})
	append(&tiles, Tile{"memory", "Memory", size_text(mem_used(m)), {{&m.mem_hist, hue(app, HUE_MEMORY), ""}}, 100, 0, mem, {.Memory, 0}})
	busiest, active := 0, f32(0)
	for d, i in m.disks { if d.active > active { busiest, active = i, d.active } }
	if len(m.disks) > 0 {
		append(&tiles, Tile{"disk", "Disk", fmt.tprintf("%s/s", size_text(u64(m.disk_rate))), {{&m.disk_hist, hue(app, HUE_DISK), ""}}, 0, DISK_FLOOR, active / 100, {.Disk, busiest}})
	}
	if len(m.nets) > 0 {
		append(&tiles, Tile{"network", "Network", bits_text(m.net_rate), {{&m.net_hist, hue(app, HUE_NETWORK), ""}}, 0, NET_FLOOR, -1, {.Network, 0}})
	}
	if len(m.gpus) > 0 {
		g := &m.gpus[0]
		value := g.read.asleep ? "asleep" : g.read.has_util ? fmt.tprintf("%.0f%%", g.read.util) : "–"
		append(&tiles, Tile{"gpu", "GPU", value, {{&g.util_hist, hue(app, HUE_GPU), ""}}, 100, 0, g.read.has_util ? g.read.util / 100 : -1, {.Gpu, 0}})
	}
	if m.temp_count > 0 {
		c := m.temps[0].celsius
		append(&tiles, Tile{"temperature", "Temperature", fmt.tprintf("%.0f °C", c), {{&m.temp_hist, hue(app, HUE_HEAT), ""}}, TEMP_TOP, 0, (c - SUMMARY_TEMP_COOL) / (SUMMARY_TEMP_HOT - SUMMARY_TEMP_COOL), {.Cpu, 0}})
	}
	if m.has_pressure {
		worst := pressure_worst(m)
		p := m.pressure[worst].some10
		append(&tiles, Tile{"pressure", fmt.tprintf("Pressure, %s", PRESSURE_NAMES[worst]), fmt.tprintf("%.1f%%", p), pressure_series(app), 0, PRESSURE_FLOOR, p / SUMMARY_PRESSURE_FULL, {.Pressure, 0}})
	}

	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * SUMMARY_EM)), bg = surface("bar")})
	if ui.row(.Center, {.Draw_Background, .Draw_Side_Bottom}, "###summary") {
		for t, i in tiles {
			if i > 0 { vrule(em, 2) }
			summary_tile(app, t, em)
		}
	}
}

@(private = "file")
summary_tile :: proc(app: ^App, t: Tile, em: f32) {
	ui.next({width = ui.fill(), height = ui.pct(1)})
	sig: ui.Signal
	if ui.row(.Center, {.Clickable, .Draw_Hot_Effects, .Hot_Within}, fmt.tprintf("###sum_%s", t.id)) {
		sig = ui.signal(ui.parent_box())
		// the stripe: the colour of the load (green to red), or the accent for what has no scale
		stripe := t.load >= 0 ? heat_hue(t.load, luminance(ui.color("background")) < HEAT_DARK_PAGE) : ui.color("accent")
		ui.next({width = ui.px(max(3, em * 0.22)), height = ui.pct(0.6), bg = stripe})
		ui.build_box({.Draw_Background}, "###stripe")
		ui.spacer(ui.px(em * 0.5))
		// (the words as wide as the wider of the two: the sparkline takes what is left)
		font := app.shared.font
		words := max(ui.text_width(font, em * 0.82, t.title), ui.text_width(font, em, t.value))
		ui.next({width = ui.px(words + em * 0.2), height = ui.pct(1), axis = .Y})
		if ui.column(id = "###words") {
			ui.spacer(ui.fill())
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.px(em * 1.2), font_size = em * 0.82, text_pad = 0})
				ui.label(fmt.tprintf("%s###title", t.title))
			}
			ui.next({width = ui.fill(), height = ui.px(em * 1.35), text_pad = 0})
			ui.label(fmt.tprintf("%s###value", t.value))
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em * 0.5))
		ui.next({width = ui.fill(), height = ui.pct(0.62)})
		ui.sparkline("###spark", line_series(t.series), t.top, HISTORY_POINTS, t.floor)
		ui.spacer(ui.px(em * 0.5))
	}
	tip_after(sig, fmt.tprintf("%s: %s. Show it in Performance", t.title, t.value))
	if sig.clicked {
		tab_show(app, .Performance)
		app.device = t.device
		cpu_grid_set(app, false)
	}
}

// Shows or hides the summary (written to processes.summary).
summary_switch :: proc(app: ^App) {
	app.settings.summary = !app.settings.summary
	pref_save(&app.prefs, "processes.summary", app.settings.summary ? "true" : "false")
	tab_show(app, .Processes)
	say(app, app.settings.summary ? "The summary of the machine is shown" : "The summary of the machine is hidden")
}
