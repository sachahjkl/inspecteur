package inspecteur

// The Information section: what the system is, in groups of lines (information.odin reads it). "Copy all" (Ctrl+C)
// copies the same lines as plain text; F5 reads them again.

import "core:fmt"
import "core:strings"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"
import i18n "gt:i18n"

INFO_KEY_EM :: 13   // the labels' column
INFO_WIDTH_EM :: 60  // the text's width at most: long lines read badly

Info_Line :: struct { key, value: string }
Info_Group :: struct { title, icon: string, lines: []Info_Line }

// The report: the thread's reading and the last sample's numbers, in groups (temporary allocator). The view shows it,
// Copy all copies it.
info_report :: proc(app: ^App) -> []Info_Group {
	s := app.information.data
	groups := make([dynamic]Info_Group, context.temp_allocator)
	lines := make([dynamic]Info_Line, context.temp_allocator)
	add :: proc(lines: ^[dynamic]Info_Line, key, value: string) { if value != "" { append(lines, Info_Line{key, value}) } }
	group :: proc(groups: ^[dynamic]Info_Group, lines: ^[dynamic]Info_Line, title, icon: string) {
		if len(lines) == 0 { return }
		append(groups, Info_Group{title, icon, lines[:]})
		lines^ = make([dynamic]Info_Line, context.temp_allocator)
	}
	m := &app.machine
	if s != nil {
		add(&lines, i18n.tr("Operating system"), s.os_name)
		add(&lines, i18n.tr("Kernel"), s.kernel)
		add(&lines, i18n.tr("Architecture"), s.arch)
		add(&lines, i18n.tr("Computer name"), s.hostname)
	}
	add(&lines, i18n.tr("Up for"), duration_words(m.uptime))
	if s != nil {
		add(&lines, i18n.tr("Desktop"), s.desktop)
		add(&lines, i18n.tr("Session"), s.display != "" ? s.display : s.session)
		add(&lines, i18n.tr("Computer"), s.computer)
		add(&lines, i18n.tr("Motherboard"), s.board)
		add(&lines, i18n.tr("Firmware"), s.firmware)
	}
	group(&groups, &lines, i18n.tr("System"), lucide.MONITOR)

	if s != nil && s.cpu.logical > 0 {
		add(&lines, i18n.tr("Model"), s.cpu.model)
		add(&lines, i18n.tr("Cores"), cores_text(s.cpu.cores, s.cpu.logical, s.cpu.sockets))
	}
	group(&groups, &lines, i18n.tr("Processor"), lucide.CPU)

	add(&lines, i18n.tr("Installed"), size_text(m.mem.total))
	add(&lines, i18n.tr("Available now"), size_text(m.mem.available))
	add(&lines, i18n.tr("Swap"), m.mem.swap_total > 0 ? size_text(m.mem.swap_total) : i18n.tr("none"))
	group(&groups, &lines, i18n.tr("Memory"), lucide.LAYERS_2)

	if s != nil {
		for g in s.gpus {
			name := g.name
			// (no pci.ids: the GPU's own library may name it, as Performance shows)
			if !g.named { for &mg in m.gpus { if mg.read.vendor == g.vendor && gpu_name(&mg.read) != "" { name = gpu_name(&mg.read) } } }
			add(&lines, name, g.driver != "" ? fmt.tprintf(i18n.tr("PCI %s at %s, driver %s"), g.ids, g.slot, g.driver) : fmt.tprintf(i18n.tr("PCI %s at %s"), g.ids, g.slot))
		}
	}
	group(&groups, &lines, i18n.tr("Graphics"), lucide.APP_WINDOW)

	for &d in m.disks {
		add(&lines, d.name, strings.join({d.model != "" ? d.model : i18n.tr("Disk"), i18n.tr(d.kind), size_text(d.capacity)}, ", ", context.temp_allocator))
	}
	if s != nil {
		for f in s.fss {
			add(&lines, f.mount, fmt.tprintf(i18n.tr("%s free of %s (%s, %s)"), size_text(f.free), size_text(f.size), f.kind, f.device))
		}
	}
	group(&groups, &lines, i18n.tr("Storage"), lucide.HARD_DRIVE)

	for &n in m.nets {
		parts := make([dynamic]string, context.temp_allocator)
		append(&parts, i18n.tr(n.kind))
		append(&parts, n.up ? i18n.tr("up") : i18n.tr("down"))
		if n.speed_mbps > 0 { append(&parts, fmt.tprintf("%d Mbit/s", n.speed_mbps)) }
		if n.mac != "" { append(&parts, fmt.tprintf("MAC %s", n.mac)) }
		for a in n.addrs { append(&parts, a) }
		add(&lines, n.name, strings.join(parts[:], ", ", context.temp_allocator))
	}
	group(&groups, &lines, i18n.tr("Network"), lucide.GLOBE)

	if s != nil {
		for sc in s.screens {
			add(&lines, sc.connector, strings.join({sc.name != "" ? sc.name : i18n.tr("Screen"), sc.mode}, ", ", context.temp_allocator))
		}
	}
	if win := app.main.win; win != nil {
		size := platform.monitor_size(win)
		d := platform.display_info(win)
		if size.x > 0 { add(&lines, i18n.tr("This window's screen"), fmt.tprintf(i18n.tr("%d×%d logical pixels, %.0f Hz"), size.x, size.y, d.hz)) }
	}
	group(&groups, &lines, i18n.tr("Displays"), lucide.MONITOR)

	if s != nil {
		for b in s.batteries {
			v := fmt.tprintf("%d%%, %s", b.capacity, battery_status_text(b.status))
			if b.health >= 0 { v = fmt.tprintf(i18n.tr("%s; holds %d%% of its design capacity"), v, b.health) }
			if b.model != "" { v = fmt.tprintf("%s; %s", v, b.model) }
			if b.technology != "" && b.technology != "Unknown" { v = fmt.tprintf("%s, %s", v, b.technology) }
			add(&lines, b.name, v)
		}
	}
	group(&groups, &lines, i18n.tr("Battery"), lucide.PLUG)
	return groups[:]
}

// "8 cores, 16 logical processors" (", 2 sockets" when there are more than one).
@(private = "file")
cores_text :: proc(cores, logical, sockets: int) -> string {
	text := fmt.tprintf("%s, %s", fmt.tprintf(i18n.tr(cores, "%d core", "%d cores"), cores), fmt.tprintf(i18n.tr(logical, "%d logical processor", "%d logical processors"), logical))
	if sockets > 1 { text = fmt.tprintf(i18n.tr("%s, %d sockets"), text, sockets) }
	return text
}

// A battery's state as the system says it ("Charging"), in lower case: its words where they are known.
@(private = "file")
battery_status_text :: proc(status: string) -> string {
	switch status {
	case "Charging":     return i18n.tr("charging")
	case "Discharging":  return i18n.tr("discharging")
	case "Full":         return i18n.tr("full")
	case "Not charging": return i18n.tr("not charging")
	}
	return strings.to_lower(status, context.temp_allocator)
}

// The report as plain text: a title per group, then "label: value" lines.
info_text :: proc(groups: []Info_Group) -> string {
	b := strings.builder_make(context.temp_allocator)
	for g, i in groups {
		if i > 0 { strings.write_byte(&b, '\n') }
		fmt.sbprintf(&b, "%s\n", g.title)
		for l in g.lines { fmt.sbprintf(&b, "  %s: %s\n", l.key, l.value) }
	}
	return strings.to_string(b)
}

build_information :: proc(app: ^App, em: f32) {
	inf := &app.information
	busy := information_busy(inf)
	section_bar(app, i18n.tr("Information"), busy && inf.data == nil ? i18n.tr("Reading…") : i18n.tr("This computer and its system"), em, info_actions)
	groups := info_report(app)
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###info") {
		ui.spacer(ui.px(em * 0.6))
		for g, k in groups {
			// (the lines straight in the scroll: a wrapped paragraph's height is known only there)
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
			if ui.row(.Center, {}, fmt.tprintf("###head_%d", k)) {
				ui.spacer(ui.px(em * 0.8))
				ui.icon(g.icon, em * 1.6, ui.color("accent"))
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.text_size(), height = ui.pct(1), font_size = em * 1.15, text_pad = 0})
				ui.label(fmt.tprintf("%s###title", g.title))
			}
			for l, i in g.lines { info_line(l, k * 1000 + i, em) }
			ui.spacer(ui.px(em * 0.6))
		}
	}
}

// A line: its label, its value (wrapped).
@(private = "file")
info_line :: proc(l: Info_Line, i: int, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.row(.Start, {}, fmt.tprintf("###line_%d", i)) {
		ui.spacer(ui.px(em * 3))
		if ui.tags("weak") {
			ui.next({width = ui.px(em * INFO_KEY_EM)})
			if ui.style({text_pad = 0}) { ui.paragraph(fmt.tprintf("%s###k", ui.text_shown(l.key))) }
		}
		ui.spacer(ui.px(em * 0.6))
		ui.next({width = ui.px(em * INFO_WIDTH_EM)})
		if ui.style({text_pad = 0}) { ui.paragraph(fmt.tprintf("%s###v", ui.text_shown(l.value))) }
		ui.spacer(ui.fill())
	}
	ui.spacer(ui.px(em * 0.3))
}

@(private = "file")
info_actions :: proc(app: ^App, em: f32) {
	cmd_button(app, "copy_all", lucide.COPY, .Info_Copy, em)
	if tool_button("read_again", lucide.REFRESH_CW, cmd_tip(.Read_Again), !information_busy(&app.information), em) { refresh_now(app) }
}

info_copy :: proc(app: ^App) {
	text := info_text(info_report(app))
	platform.set_clipboard(app.main.win, text)
	n := strings.count(text, "\n")
	announce(app, fmt.tprintf(i18n.tr(n, "Copied the system's information (%d lines)", "Copied the system's information (%d lines)"), n))
}
