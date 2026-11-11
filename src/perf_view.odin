package inspecteur

// The Performance section: the devices on the left (CPU, memory, each disk, each network interface, each GPU), each with
// a sparkline of its history; the selected device on the right: its graphs and its numbers. The CPU's page shows one
// graph for all the processors, or one per logical processor (the grid, Ctrl+G). Up and Down go from a device to the
// next. A graph's span is its points times the period of its readings: processes.refresh_ms, or GPU_PERIOD for a GPU.

import "core:fmt"
import "core:strings"
import "core:time"
import "gt:draw"
import "gt:ui"

Device_Kind :: enum u8 { Cpu, Memory, Disk, Network, Gpu, Pressure }

Device :: struct {
	kind:  Device_Kind,
	index: int,   // the disk's, the interface's, the GPU's
}

DEVICE_LIST_EM  :: 17     // the list's width
DEVICE_ROW_EM   :: 3.6    // a device's line
SPARK_W_EM      :: 4.6    // its sparkline
SPARK_H_EM      :: 2.6
GRAPH_MIN_EM    :: 8      // a graph's least height
STAT_W_EM       :: 9.5    // a number of the page's
KEYS_W_EM       :: 26     // the page's table of details
CPU_GRID_GAP_EM :: 0.4
ADDRESSES_SHOWN :: 3    // an interface's addresses of each kind shown

// The hues of the devices (hue).
HUE_CPU, HUE_MEMORY, HUE_DISK, HUE_NETWORK, HUE_GPU, HUE_SECOND, HUE_HEAT :: 1, 2, 3, 4, 6, 7, 5
// A temperature graph's top (its graph is the same height whatever the reading), and the height of a second graph of a
// page (the temperature under the utilization), in ems.
TEMP_TOP      :: 100
SMALL_GRAPH_EM :: 6
// The least top of a rate's graph: a disk at rest, or an interface, does not fill its graph with its noise.
DISK_FLOOR :: 1024 * 1024          // 1 MB/s
NET_FLOOR  :: 1_000_000 / 8        // 1 Mbit/s, in bytes per second

build_performance :: proc(app: ^App, em: f32) {
	m := &app.machine
	device_check(app)
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * BAR_EM))})
	if ui.row(.Center, {.Draw_Side_Bottom}, "###bar") {
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = 0})
		ui.label("Performance###bar_title")
		ui.spacer(ui.fill())
		if app.device.kind == .Cpu {
			ui.next({width = ui.px(em * 21), height = ui.px(ui.dense(em * 1.9))})
			labels := []string{"Overall", "Logical processors"}
			sel := app.cpu_grid ? 1 : 0
			// (the key that switches them, in each segment's tooltip)
			key := ui.command_shortcut(COMMANDS[.Cpu_Grid])
			tips := []string{fmt.tprintf("One graph for all the processors (%s)", key), fmt.tprintf("One graph per logical processor (%s)", key)}
			if ui.segmented("###cpu_view", labels, &sel, tips) { app.cpu_grid = sel == 1 }
		}
		ui.spacer(ui.px(em * 0.6))
	}
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.row(id = "###perf") {
		ui.next({width = ui.px(em * DEVICE_LIST_EM), height = ui.pct(1), axis = .Y})
		list := ui.build_box({.Clip, .Draw_Side_Right}, "###devices")
		if ui.parent(list) {
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.scroll_y("###devices_scroll") {
				device_row(app, {.Cpu, 0}, "CPU", fmt.tprintf("%.0f%%  %s%s", m.cpu, mhz_text(m.mhz), m.temp_count > 0 ? fmt.tprintf("  %.0f °C", m.temps[0].celsius) : ""), {{&m.cpu_hist, hue(app, HUE_CPU), ""}}, 100, 0, em)
				device_row(app, {.Memory, 0}, "Memory", fmt.tprintf("%s / %s (%.0f%%)", size_text(mem_used(m)), size_text(m.mem.total), ui.value_history_last(&m.mem_hist)), {{&m.mem_hist, hue(app, HUE_MEMORY), ""}}, 100, 0, em)
				for &d, i in m.disks {
					device_row(app, {.Disk, i}, fmt.tprintf("Disk %d (%s)", i, d.name), fmt.tprintf("%s  %.0f%%", d.kind, d.active), {{&d.active_hist, hue(app, HUE_DISK), ""}}, 100, 0, em)
				}
				for &n, i in m.nets {
					device_row(app, {.Network, i}, n.kind, fmt.tprintf("%s  S: %s R: %s", n.name, bits_text(n.tx_rate), bits_text(n.rx_rate)), {{&n.rx_hist, hue(app, HUE_NETWORK), ""}, {&n.tx_hist, hue(app, HUE_SECOND), ""}}, 0, NET_FLOOR, em)
				}
				for &g, i in m.gpus {
					sub := gpu_name(&g.read)
					switch {
					case g.read.asleep:   sub = fmt.tprintf("%s  asleep", sub)
					case g.read.has_util: sub = fmt.tprintf("%s  %.0f%%", sub, g.read.util)
					}
					device_row(app, {.Gpu, i}, fmt.tprintf("GPU %d", i), sub, {{&g.util_hist, hue(app, HUE_GPU), ""}}, 100, 0, em)
				}
				if m.has_pressure {
					worst := pressure_worst(m)
					device_row(app, {.Pressure, 0}, "Pressure", fmt.tprintf("%s waits %.1f%%", PRESSURE_NAMES[worst], m.pressure[worst].some10), pressure_series(app), 0, PRESSURE_FLOOR, em)
				}
			}
		}
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column(id = "###device") {
			ui.spacer(ui.px(em * 0.8))
			ui.next({width = ui.fill(), height = ui.fill()})
			if ui.row(id = "###device_pad") {
				ui.spacer(ui.px(em * 1.2))
				ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
				if ui.column(id = "###device_page") {
					switch app.device.kind {
					case .Cpu:     cpu_page(app, em)
					case .Memory:  memory_page(app, em)
					case .Disk:    disk_page(app, &m.disks[app.device.index], em)
					case .Network: net_page(app, &m.nets[app.device.index], em)
					case .Gpu:     gpu_page(app, &m.gpus[app.device.index], em)
					case .Pressure: pressure_page(app, em)
					}
				}
				ui.spacer(ui.px(em * 1.2))
			}
			ui.spacer(ui.px(em * 0.8))
		}
	}
}

// The device after (`dir` 1) or before (-1) the one shown, in the list's order.
device_step :: proc(app: ^App, dir: int) {
	m := &app.machine
	list := make([dynamic]Device, context.temp_allocator)
	append(&list, Device{.Cpu, 0}, Device{.Memory, 0})
	for _, i in m.disks { append(&list, Device{.Disk, i}) }
	for _, i in m.nets { append(&list, Device{.Network, i}) }
	for _, i in m.gpus { append(&list, Device{.Gpu, i}) }
	if m.has_pressure { append(&list, Device{.Pressure, 0}) }
	at := 0
	for d, i in list { if d == app.device { at = i } }
	app.device = list[clamp(at + dir, 0, len(list) - 1)]
}

// The CPU's page: one graph, or one per logical processor.
cpu_grid_switch :: proc(app: ^App) {
	app.device = {.Cpu, 0}
	app.cpu_grid = !app.cpu_grid
}

// A device that went (an interface, a GPU no longer read): back to the CPU.
@(private = "file")
device_check :: proc(app: ^App) {
	d := app.device
	m := &app.machine
	switch d.kind {
	case .Cpu, .Memory:
	case .Disk:    if d.index >= len(m.disks) { app.device = {} }
	case .Network: if d.index >= len(m.nets) { app.device = {} }
	case .Gpu:     if d.index >= len(m.gpus) { app.device = {} }
	case .Pressure: if !m.has_pressure { app.device = {} }
	}
}

// A series of a graph: its history, its colour, its name in the graph's legend ("": none).
Series :: struct {
	hist:  ^History,
	color: ui.Color,
	name:  string,
}

// The series as the toolkit's graph takes them.
line_series :: proc(series: []Series) -> []ui.Line_Series {
	out := make([]ui.Line_Series, len(series), context.temp_allocator)
	for s, i in series { out[i] = {ui.value_history_values(s.hist), s.color} }
	return out
}

// The theme's hue `i` (0 accent, 1 blue, 2 purple, 3 green, 4 yellow, 5 red, 6 cyan, 7 rose) in the version shown.
hue :: proc(app: ^App, i: int) -> ui.Color {
	c, _ := ui.theme_version(app.theme_shown.def, app.theme_shown.light)
	return draw.hex(c.hues[i])
}

@(private = "file")
device_row :: proc(app: ^App, d: Device, title, sub: string, series: []Series, top, floor: f32, em: f32) {
	on := app.device == d
	flags := ui.Box_Flags{.Clickable, .Draw_Hot_Effects, .Hot_Within}
	if on { flags += {.Draw_Background} }
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * DEVICE_ROW_EM)), bg = on ? ui.color("border") : nil})
	sig: ui.Signal
	if ui.row(.Center, flags, fmt.tprintf("###dev_%d_%d", int(d.kind), d.index)) {
		sig = ui.signal(ui.parent_box())
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.px(em * SPARK_W_EM), height = ui.px(em * SPARK_H_EM)})
		frame := ui.build_box({.Draw_Border}, "###spark_frame")
		if ui.parent(frame) {
			ui.next({width = ui.fill(), height = ui.fill()})
			ui.sparkline("###spark", line_series(series), top, HISTORY_POINTS, floor)
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.fill(), height = ui.pct(1), axis = .Y})
		if ui.column() {
			ui.spacer(ui.fill())
			ui.next({width = ui.fill(), height = ui.px(em * 1.35), text_pad = 0})
			ui.label(fmt.tprintf("%s###t", title))
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.px(em * 1.25), text_pad = 0, font_size = em * 0.86})
				sub_box := ui.build_box({.Draw_Text}, fmt.tprintf("%s###s", ui.text_shown(sub)))
				// (a subtitle too long for the list says itself whole when the pointer rests on the device)
				if text_cut(sub_box, sub) { tip_after(sig, sub) }
			}
			ui.spacer(ui.fill())
		}
		ui.spacer(ui.px(em * 0.4))
	}
	if sig.clicked {
		app.device = d
		ui.set_focus(0)   // (Up and Down then go from a device to the next, not from a button to another)
	}
}

////////////////////////////////
// The pages

// The page's title, and what it is at its right (the model, the adapter).
@(private = "file")
page_title :: proc(title, what: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 2.4)})
	if ui.row(.Center, {}, "###page_title") {
		ui.next({width = ui.text_size(), height = ui.pct(1), font_size = em * 1.7, text_pad = 0})
		ui.label(fmt.tprintf("%s###title", title))
		ui.spacer(ui.fill())
		if ui.tags("weak") {
			ui.next({width = ui.text_size(), height = ui.pct(1), font_size = em * 1.05, text_pad = 0})
			ui.label(fmt.tprintf("%s###what", ui.text_shown(what)))
		}
	}
	ui.spacer(ui.px(em * 0.5))
}

// A graph with its captions: what it shows and its top above it, its span and its bottom under it.
captioned_graph :: proc(app: ^App, id, what: string, series: []Series, top: f32, top_text: proc(v: f32) -> string, em: f32, height: ui.Size, floor: f32 = 0, period_ms := 0) {
	lines := line_series(series)
	shown_top := ui.line_graph_top(lines, {top = top, floor = floor})
	// what it shows, the legend of its series (a swatch and a name each), its top
	ui.next({width = ui.fill(), height = ui.px(em * 1.5)})
	if ui.row(.Center, {}, fmt.tprintf("###%s_caption", id)) {
		if ui.tags("weak") {
			if ui.style({font_size = em * 0.85, text_pad = 0}) {
				ui.next({width = ui.text_size(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###l", what))
				for s, i in series {
					if s.name == "" { continue }
					ui.spacer(ui.px(em))
					ui.next({width = ui.px(em * 0.75), height = ui.px(em * 0.75), bg = s.color})
					ui.build_box({.Draw_Background}, fmt.tprintf("###swatch%d", i))
					ui.next({width = ui.text_size(), height = ui.pct(1), text_pad = em * 0.3})
					ui.label(fmt.tprintf("%s###name%d", s.name, i))
				}
				ui.spacer(ui.fill())
				ui.next({width = ui.text_size(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###r", top_text(shown_top)))
			}
		}
	}
	ui.next({width = ui.fill(), height = height})
	ui.line_graph(fmt.tprintf("###%s", id), lines, {top = shown_top, points = HISTORY_POINTS, grid = true})
	caption(span_text(HISTORY_POINTS, period_ms > 0 ? period_ms : app.settings.refresh_ms), "0", em)
}

@(private = "file")
caption :: proc(left, right: string, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.5)})
	if ui.row(.Center) {
		if ui.tags("weak") {
			if ui.style({font_size = em * 0.85, text_pad = 0}) {
				ui.next({width = ui.fill(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###l", left))
				ui.next({width = ui.text_size(), height = ui.pct(1)})
				ui.label(fmt.tprintf("%s###r", right))
			}
		}
	}
}

percent_top :: proc(v: f32) -> string { return fmt.tprintf("%.0f%%", v) }
celsius_top :: proc(v: f32) -> string { return fmt.tprintf("%.0f °C", v) }
rate_top :: proc(v: f32) -> string { return fmt.tprintf("%s/s", size_text(u64(v))) }

// The numbers under the graphs: big ones on the left, a table of details on the right.
Stat :: struct { label, value: string }

@(private = "file")
stats_block :: proc(big: []Stat, details: []Stat, em: f32) {
	ui.spacer(ui.px(em * 0.8))
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.row(id = "###stats") {
		ui.next({width = ui.fill(), height = ui.children_sum()})
		if ui.flow({em * 0.4, em * 0.6}, "###big") {
			for s, i in big {
				ui.next({width = ui.px(em * STAT_W_EM), height = ui.children_sum(), axis = .Y})
				if ui.column(id = fmt.tprintf("###big%d", i)) {
					if ui.tags("weak") {
						ui.next({width = ui.fill(), height = ui.px(em * 1.3), font_size = em * 0.86, text_pad = 0})
						ui.label(fmt.tprintf("%s###l", s.label))
					}
					ui.next({width = ui.fill(), height = ui.px(em * 1.8), font_size = em * 1.3, text_pad = 0})
					ui.label(fmt.tprintf("%s###v", ui.text_shown(s.value)))
				}
			}
		}
		ui.spacer(ui.px(em))
		ui.next({width = ui.px(em * KEYS_W_EM), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###details") {
			for s, i in details {
				ui.next({width = ui.fill(), height = ui.children_sum()})
				if ui.row(.Start, {}, fmt.tprintf("###d%d", i)) {
					if ui.tags("weak") {
						ui.next({width = ui.px(em * 11), height = ui.px(em * 1.5), text_pad = 0})
						ui.label(fmt.tprintf("%s###l", s.label))
					}
					ui.next({width = ui.fill()})
					if ui.style({text_pad = 0}) { ui.paragraph(fmt.tprintf("%s###v", ui.text_shown(s.value))) }
				}
			}
		}
	}
}

@(private = "file")
cpu_page :: proc(app: ^App, em: f32) {
	m := &app.machine
	page_title("CPU", m.info.model, em)
	c := hue(app, HUE_CPU)
	if app.cpu_grid && len(m.core_hist) > 0 {
		n := len(m.core_hist)
		cols := 1
		for cols * cols < n { cols += 1 }
		rows := (n + cols - 1) / cols
		caption(fmt.tprintf("%% Utilization of each logical processor over %s", span_text(HISTORY_POINTS, app.settings.refresh_ms)), "100%", em)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		if ui.column(id = "###grid") {
			for r in 0 ..< rows {
				if r > 0 { ui.spacer(ui.px(em * CPU_GRID_GAP_EM)) }
				ui.next({width = ui.fill(), height = ui.fill()})
				if ui.row(id = fmt.tprintf("###grid_row%d", r)) {
					for k in 0 ..< cols {
						i := r * cols + k
						if k > 0 { ui.spacer(ui.px(em * CPU_GRID_GAP_EM)) }
						ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
						if i >= n { ui.spacer(ui.fill()); continue }
						if ui.column(id = fmt.tprintf("###core_box%d", i)) {
							// (each processor's number and frequency over its graph)
							if ui.tags("weak") {
								mhz := i < len(m.core_mhz) ? m.core_mhz[i] : 0
								ui.next({width = ui.fill(), height = ui.px(em * 1.3), font_size = em * 0.8, text_pad = 0})
								celsius := i < len(m.core_celsius) ? m.core_celsius[i] : 0
								ui.label(fmt.tprintf("CPU %d%s%s###core_label", i, mhz > 0 ? fmt.tprintf("  %s", mhz_text(mhz)) : "", celsius > 0 ? fmt.tprintf("  %.0f °C", celsius) : ""))
							}
							ui.next({width = ui.fill(), height = ui.fill()})
							ui.line_graph(fmt.tprintf("###core_%d", i), line_series({{&m.core_hist[i], c, ""}}), {top = 100, points = HISTORY_POINTS, grid = true})
						}
					}
				}
			}
		}
	} else {
		captioned_graph(app, "cpu_graph", "% Utilization", {{&m.cpu_hist, c, ""}}, 100, percent_top, em, ui.fill())
		if m.temp_count > 0 {
			ui.spacer(ui.px(em * 0.4))
			captioned_graph(app, "cpu_temp", fmt.tprintf("Temperature (%s)", temp_label(&m.temps[0])), {{&m.temp_hist, hue(app, HUE_HEAT), ""}}, TEMP_TOP, celsius_top, em, ui.px(em * SMALL_GRAPH_EM))
		}
	}
	threads: i32
	for p in app.sampler.procs { threads += p.threads }
	caches := make([dynamic]Stat, context.temp_allocator)
	for size, level in m.info.cache {
		if size > 0 { append(&caches, Stat{fmt.tprintf("L%d cache", level + 1), size_text(size)}) }
	}
	details := make([dynamic]Stat, context.temp_allocator)
	if m.info.base_mhz > 0 { append(&details, Stat{"Base speed", mhz_text(m.info.base_mhz)}) }
	if m.info.max_mhz > 0 { append(&details, Stat{"Maximum speed", mhz_text(m.info.max_mhz)}) }
	append(&details, Stat{"Sockets", fmt.tprintf("%d", m.info.sockets)}, Stat{"Cores", fmt.tprintf("%d", m.info.cores)}, Stat{"Logical processors", fmt.tprintf("%d", len(m.core_total))})
	append(&details, ..caches[:])
	append(&details, Stat{"Load average", fmt.tprintf("%.2f  %.2f  %.2f", m.load[0], m.load[1], m.load[2])})
	// (the first sensor is the big Temperature; a machine with none, a CI runner's, has no others)
	if m.temp_count > 1 { for &t in m.temps[1:m.temp_count] { append(&details, Stat{temp_label(&t), fmt.tprintf("%.0f °C", t.celsius)}) } }
	// (each core's is in the logical processors' view)
	if low, high, ok := core_celsius_range(m); ok { append(&details, Stat{"Core temperatures", fmt.tprintf("%.0f to %.0f °C", low, high)}) }
	if m.throttled > m.throttled_before { append(&details, Stat{"Slowed for its heat", fmt.tprintf("%d times since Inspecteur started", m.throttled - m.throttled_before)}) }
	big := make([dynamic]Stat, context.temp_allocator)
	append(&big, Stat{"Utilization", fmt.tprintf("%.0f%%", m.cpu)}, Stat{"Speed", mhz_text(m.mhz)})
	if m.temp_count > 0 { append(&big, Stat{"Temperature", fmt.tprintf("%.0f °C", m.temps[0].celsius)}) }
	append(&big, Stat{"Up time", uptime_text(m.uptime)}, Stat{"Processes", fmt.tprintf("%d", len(app.sampler.procs))}, Stat{"Threads", fmt.tprintf("%d", threads)}, Stat{"Open files", fmt.tprintf("%d", m.handles)})
	stats_block(big[:], details[:], em)
}

@(private = "file")
memory_page :: proc(app: ^App, em: f32) {
	m := &app.machine
	mem := m.mem
	page_title("Memory", fmt.tprintf("%s", size_text(mem.total)), em)
	c := hue(app, HUE_MEMORY)
	captioned_graph(app, "memory_graph", "Memory usage", {{&m.mem_hist, c, ""}}, 100, proc(v: f32) -> string { return "100%" }, em, ui.fill())
	// the composition: in use (what the kernel cannot take back), the cache it takes back when asked (available beyond the
	// free memory), free; the graph's "in use" is the same
	in_use := mem_used(m)
	reclaimable := mem.available - min(mem.available, mem.free)
	ui.spacer(ui.px(em * 0.6))
	caption("Memory composition", "", em)
	parts := []Bar_Part{{in_use, c, "In use"}, {reclaimable, faded(c, 0.45), "Cache, given back when needed"}, {min(mem.free, mem.available), ui.color("border"), "Free"}}
	composition_bar(parts, mem.total, em)
	swap_used := mem.swap_total - min(mem.swap_total, mem.swap_free)
	// (the numbers of the composition, and what the kernel keeps besides: the files it caches, the buffers of the disks,
	// what processes share, what is still to be written)
	stats_block({
		{"In use", size_text(in_use)}, {"Available", size_text(mem.available)}, {"Free", size_text(mem.free)},
		{"Committed", fmt.tprintf("%s / %s", size_text(mem.committed), size_text(mem.commit_limit))}, {"Swap", fmt.tprintf("%s / %s", size_text(swap_used), size_text(mem.swap_total))},
	}, {
		{"Total", size_text(mem.total)}, {"Files cached", size_text(mem.cached)}, {"Disk buffers", size_text(mem.buffers)},
		{"Kernel, reclaimable", size_text(mem.reclaimable)}, {"Shared memory", size_text(mem.shared)}, {"To be written", size_text(mem.dirty)},
	}, em)
}

@(private = "file")
disk_page :: proc(app: ^App, d: ^Disk, em: f32) {
	page_title(fmt.tprintf("Disk %d (%s)", app.device.index, d.name), d.model, em)
	c := hue(app, HUE_DISK)
	captioned_graph(app, "disk_active", "Active time", {{&d.active_hist, c, ""}}, 100, percent_top, em, ui.fill())
	ui.spacer(ui.px(em * 0.4))
	captioned_graph(app, "disk_rate", "Transfer rate", {{&d.read_hist, c, "Read"}, {&d.write_hist, hue(app, HUE_SECOND), "Write"}}, 0, rate_top, em, ui.fill(), DISK_FLOOR)
	mounts := strings.join(d.mounts[:], ", ", context.temp_allocator)
	stats_block({
		{"Active time", fmt.tprintf("%.0f%%", d.active)}, {"Read speed", fmt.tprintf("%s/s", size_text(u64(d.read_rate)))}, {"Write speed", fmt.tprintf("%s/s", size_text(u64(d.write_rate)))},
	}, {
		{"Capacity", size_text(d.capacity)}, {"Type", d.kind}, {"Model", d.model}, {"Mounted on", mounts != "" ? mounts : "nothing"},
	}, em)
}

@(private = "file")
net_page :: proc(app: ^App, n: ^Net, em: f32) {
	page_title(n.kind, n.name, em)
	captioned_graph(app, "net_rate", "Throughput", {{&n.rx_hist, hue(app, HUE_NETWORK), "Receive"}, {&n.tx_hist, hue(app, HUE_SECOND), "Send"}}, 0, proc(v: f32) -> string { return bits_text(f64(v)) }, em, ui.fill(), NET_FLOOR)
	v4 := make([dynamic]string, context.temp_allocator)
	v6 := make([dynamic]string, context.temp_allocator)
	for a in n.addrs { if strings.contains(a, ":") { append(&v6, a) } else { append(&v4, a) } }
	// (the first ones: an interface may have many temporary IPv6 addresses)
	join :: proc(list: []string) -> string {
		if len(list) == 0 { return "none" }
		shown := strings.join(list[:min(len(list), ADDRESSES_SHOWN)], "\n", context.temp_allocator)
		return len(list) > ADDRESSES_SHOWN ? fmt.tprintf("%s\nand %d more", shown, len(list) - ADDRESSES_SHOWN) : shown
	}
	stats_block({
		{"Send", bits_text(n.tx_rate)}, {"Receive", bits_text(n.rx_rate)},
	}, {
		{"Adapter", n.name}, {"Type", n.kind}, {"State", n.up ? "connected" : "not connected"},
		{"Link speed", n.speed_mbps > 0 ? fmt.tprintf("%d Mbit/s", n.speed_mbps) : "unknown"},
		{"MAC address", n.mac}, {"IPv4", join(v4[:])}, {"IPv6", join(v6[:])},
	}, em)
}

@(private = "file")
gpu_page :: proc(app: ^App, g: ^Gpu, em: f32) {
	r := &g.read
	page_title(fmt.tprintf("GPU %d", app.device.index), gpu_name(r), em)
	gpu_ms := int(time.duration_milliseconds(GPU_PERIOD))
	if r.has_util {
		captioned_graph(app, "gpu_util", "Utilization", {{&g.util_hist, hue(app, HUE_GPU), ""}}, 100, percent_top, em, ui.fill(), period_ms = gpu_ms)
	}
	if r.has_mem {
		ui.spacer(ui.px(em * 0.4))
		captioned_graph(app, "gpu_mem", "Dedicated memory usage", {{&g.mem_hist, hue(app, HUE_MEMORY), ""}}, 100, proc(v: f32) -> string { return "100%" }, em, ui.fill(), period_ms = gpu_ms)
	}
	if r.has_temp && g.temp_hist.count > 0 {
		ui.spacer(ui.px(em * 0.4))
		captioned_graph(app, "gpu_temp", "Temperature", {{&g.temp_hist, hue(app, HUE_HEAT), ""}}, TEMP_TOP, celsius_top, em, ui.px(em * SMALL_GRAPH_EM), period_ms = gpu_ms)
	}
	if !r.has_util && !r.has_mem {
		if ui.tags("weak") {
			ui.next({width = ui.fill(), height = ui.px(em * 3)})
			switch {
			case r.asleep:          ui.label("This GPU is asleep: the system turned it off while nothing uses it. Reading it would wake it.###none")
			case r.vendor == "NVIDIA": ui.label("This GPU's numbers come with NVIDIA's driver library (libnvidia-ml), not found or not answering.###none")
			case:                   ui.label(fmt.tprintf("This GPU's driver tells no utilization without %s.###none", ADMIN))
			}
		}
		ui.spacer(ui.fill())
	}
	big := make([dynamic]Stat, context.temp_allocator)
	if r.has_util { append(&big, Stat{"Utilization", fmt.tprintf("%.0f%%", r.util)}) }
	if r.has_mem { append(&big, Stat{"Dedicated memory", fmt.tprintf("%s / %s", size_text(r.mem_used), size_text(r.mem_total))}) }
	if r.has_temp { append(&big, Stat{"Temperature", fmt.tprintf("%.0f °C", r.temp_c)}) }
	if r.has_power { append(&big, Stat{"Power", fmt.tprintf("%.0f W", r.power_w)}) }
	details := make([dynamic]Stat, context.temp_allocator)
	append(&details, Stat{"Vendor", r.vendor})
	append(&details, Stat{"State", r.asleep ? "asleep" : "awake"})
	if r.has_clock { append(&details, Stat{"Clock", mhz_text(r.clock_mhz)}) }
	if r.driver_len > 0 { append(&details, Stat{"Driver version", gpu_driver(r)}) }
	stats_block(big[:], details[:], em)
}

// The pressure's graph: the share of the time some task waited, for each resource, over 10 s.
PRESSURE_FLOOR :: 10   // percent: a calm machine does not fill its graph with noise
PRESSURE_HUES := [Pressure_Kind]int{.Cpu = HUE_CPU, .Memory = HUE_MEMORY, .Io = HUE_DISK}

pressure_series :: proc(app: ^App) -> []Series {
	out := make([]Series, len(Pressure_Kind), context.temp_allocator)
	for k in Pressure_Kind { out[int(k)] = {&app.machine.pressure_hist[k], hue(app, PRESSURE_HUES[k]), PRESSURE_NAMES[k]} }
	return out
}

// The resource the most waited on now.
pressure_worst :: proc(m: ^Machine) -> Pressure_Kind {
	worst := Pressure_Kind.Cpu
	for k in Pressure_Kind { if m.pressure[k].some10 > m.pressure[worst].some10 { worst = k } }
	return worst
}

@(private = "file")
pressure_page :: proc(app: ^App, em: f32) {
	m := &app.machine
	page_title("Pressure", "the time tasks waited for a resource", em)
	captioned_graph(app, "pressure_graph", "% of the time some task waited, over 10 s", pressure_series(app), 0, percent_top, em, ui.fill(), PRESSURE_FLOOR)
	big := make([dynamic]Stat, context.temp_allocator)
	details := make([dynamic]Stat, context.temp_allocator)
	for k in Pressure_Kind {
		p := m.pressure[k]
		append(&big, Stat{fmt.tprintf("%s, some", PRESSURE_NAMES[k]), fmt.tprintf("%.1f%%", p.some10)})
		append(&details, Stat{fmt.tprintf("%s, some task", PRESSURE_NAMES[k]), fmt.tprintf("%.1f%% over 10 s, %.1f%% over 60 s", p.some10, p.some60)})
		append(&details, Stat{fmt.tprintf("%s, every task", PRESSURE_NAMES[k]), fmt.tprintf("%.1f%% over 10 s, %.1f%% over 60 s", p.full10, p.full60)})
	}
	stats_block(big[:], details[:], em)
}

////////////////////////////////
// The composition bar

Bar_Part :: struct { bytes: u64, color: ui.Color, label: string }

@(private = "file")
composition_bar :: proc(parts: []Bar_Part, total: u64, em: f32) {
	ui.next({width = ui.fill(), height = ui.px(em * 1.6)})
	if ui.row(id = "###composition") {
		for p, i in parts {
			share := total > 0 ? f32(f64(p.bytes) / f64(total)) : 0
			if share <= 0 { continue }
			ui.next({width = ui.pct(share), height = ui.pct(1), bg = p.color})
			ui.build_box({.Draw_Background, .Draw_Border}, fmt.tprintf("###part%d", i))
		}
	}
	ui.spacer(ui.px(em * 0.3))
	ui.next({width = ui.fill(), height = ui.px(em * 1.5)})
	if ui.row(.Center, {}, "###legend") {
		for p, i in parts {
			ui.next({width = ui.px(em * 0.8), height = ui.px(em * 0.8), bg = p.color})
			ui.build_box({.Draw_Background}, fmt.tprintf("###swatch%d", i))
			if ui.tags("weak") {
				ui.next({width = ui.text_size(), height = ui.pct(1), font_size = em * 0.86, text_pad = em * 0.35})
				ui.label(fmt.tprintf("%s %s###legend%d", p.label, size_text(p.bytes), i))
			}
			ui.spacer(ui.px(em))
		}
	}
}

faded :: proc(c: ui.Color, a: f32) -> ui.Color {
	out := c
	out.a *= a
	return out
}
