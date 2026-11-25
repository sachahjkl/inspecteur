package inspecteur

// Windows System Information view (information_windows.odin): Windows edition/build,
// elevation status, SMBIOS computer/board/firmware, CPU, memory/pagefile/pools, DXGI GPUs,
// physical disks & NTFS/ReFS volumes, network adapters, displays, and battery health.

import "core:fmt"
import "core:math"
import "core:strings"
import i18n "gt:i18n"
import lucide "gt:lucide"
import "gt:platform"
import timefmt "gt:timefmt"
import "gt:ui"

INFO_KEY_EM   :: 14
INFO_WIDTH_EM :: 60
INFO_ICON_EM  :: 1.6

Info_Line  :: struct { key, value: string }
Info_Group :: struct { title, icon: string, lines: []Info_Line }

info_report :: proc(app: ^App) -> []Info_Group {
	s := app.information.data
	groups := make([dynamic]Info_Group, context.temp_allocator)
	lines  := make([dynamic]Info_Line, context.temp_allocator)
	add :: proc(lines: ^[dynamic]Info_Line, key, value: string) { if value != "" { append(lines, Info_Line{key, value}) } }
	group :: proc(groups: ^[dynamic]Info_Group, lines: ^[dynamic]Info_Line, title, icon: string) {
		if len(lines) == 0 { return }
		append(groups, Info_Group{title, icon, lines[:]})
		lines^ = make([dynamic]Info_Line, context.temp_allocator)
	}

	m := &app.machine
	if s != nil {
		add(&lines, i18n.tr("Operating system"), s.os_name)
		add(&lines, i18n.tr("OS build"), s.build)
		add(&lines, i18n.tr("Architecture"), s.arch)
		add(&lines, i18n.tr("Computer name"), s.hostname)
		add(&lines, i18n.tr("Privilege level"), s.elevated ? i18n.tr("Administrator (elevated)") : i18n.tr("Standard user"))
	}
	add(&lines, i18n.tr("Up for"), duration_words(m.uptime))
	if s != nil {
		add(&lines, i18n.tr("Computer"), s.computer)
		add(&lines, i18n.tr("Motherboard"), s.board)
		add(&lines, i18n.tr("Firmware"), s.firmware)
	}
	group(&groups, &lines, i18n.tr("System"), lucide.MONITOR)

	if s != nil && s.cpu.logical > 0 {
		add(&lines, i18n.tr("Model"), s.cpu.model)
		add(&lines, i18n.tr("Cores"), win_cores_text(s.cpu.cores, s.cpu.logical, s.cpu.sockets))
	}
	group(&groups, &lines, i18n.tr("Processor"), lucide.CPU)

	add(&lines, i18n.tr("Installed"), timefmt.size(i64(m.mem.total)))
	add(&lines, i18n.tr("Available now"), timefmt.size(i64(m.mem.available)))
	add(&lines, i18n.tr("Committed"), fmt.tprintf("%s / %s", timefmt.size(i64(m.mem.committed)), timefmt.size(i64(m.mem.commit_limit))))
	add(&lines, i18n.tr("Pagefile"), m.mem.swap_total > 0 ? timefmt.size(i64(m.mem.swap_total)) : i18n.tr("none"))
	add(&lines, i18n.tr("Kernel pools"), fmt.tprintf(i18n.tr("Paged %s, non-paged %s"), timefmt.size(i64(m.mem.reclaimable)), timefmt.size(i64(m.mem.buffers))))
	group(&groups, &lines, i18n.tr("Memory"), lucide.LAYERS_2)

	if s != nil {
		for g in s.gpus {
			add(&lines, g.name, fmt.tprintf(i18n.tr("%s, PCI %s, %s dedicated VRAM"), g.vendor, g.ids, timefmt.size(i64(g.vram_bytes))))
		}
	}
	group(&groups, &lines, i18n.tr("Graphics"), lucide.APP_WINDOW)

	for &d in m.disks {
		add(&lines, d.name, strings.join({d.model != "" ? d.model : i18n.tr("Disk"), i18n.tr(d.kind), timefmt.size(i64(d.capacity))}, ", ", context.temp_allocator))
	}
	if s != nil {
		for v in s.volumes {
			key := v.label != "" ? fmt.tprintf("%s (%s)", v.drive, v.label) : v.drive
			add(&lines, key, fmt.tprintf(i18n.tr("%s free of %s (%s)"), timefmt.size(i64(v.free)), timefmt.size(i64(v.size)), v.fs != "" ? v.fs : "?"))
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
		for sc in s.displays {
			add(&lines, sc.device, strings.join({sc.name != "" ? sc.name : i18n.tr("Screen"), sc.mode}, ", ", context.temp_allocator))
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
			v := fmt.tprintf("%s, %s", percent_text(f64(b.capacity)), b.status)
			if b.health >= 0 { v = fmt.tprintf(i18n.tr("%s; holds %s of its design capacity"), v, percent_text(f64(b.health))) }
			add(&lines, b.name, v)
		}
	}
	group(&groups, &lines, i18n.tr("Battery"), lucide.PLUG)
	return groups[:]
}

@(private = "file")
win_cores_text :: proc(cores, logical, sockets: int) -> string {
	text := fmt.tprintf("%s, %s", fmt.tprintf(i18n.tr(cores, "%d core", "%d cores"), cores), fmt.tprintf(i18n.tr(logical, "%d logical processor", "%d logical processors"), logical))
	if sockets > 1 { text = fmt.tprintf(i18n.tr("%s, %d sockets"), text, sockets) }
	return text
}

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
	section_bar(app, i18n.tr("Information"), busy && inf.data == nil ? i18n.tr("Reading…") : i18n.tr("This computer and its system"), em, win_info_actions)
	groups := info_report(app)
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###info") {
		ui.space(ui.SPACE_2)
		for g, k in groups {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
			if ui.row(.Center, {}, fmt.tprintf("###head_%d", k)) {
				ui.space(ui.SPACE_3)
				ui.icon(g.icon, em * INFO_ICON_EM, ui.color("accent"))
				ui.space(ui.ICON_GAP)
				ui.next({width = ui.text_size(), height = ui.pct(1), font_size = em * 1.15, text_pad = 0})
				ui.label(fmt.tprintf("%s###title", g.title))
			}
			for l, i in g.lines { win_info_line(l, k * 1000 + i, em) }
			ui.space(ui.SPACE_2)
		}
	}
}

@(private = "file")
win_info_line :: proc(l: Info_Line, i: int, em: f32) {
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.row(.Start, {}, fmt.tprintf("###line_%d", i)) {
		ui.spacer(ui.px(math.round(em * ui.SPACE_3) + em * INFO_ICON_EM + math.round(em * ui.ICON_GAP)))
		if ui.tags("weak") {
			ui.next({width = ui.px(em * INFO_KEY_EM)})
			if ui.style({text_pad = 0}) { ui.paragraph(fmt.tprintf("%s###k", ui.text_shown(l.key))) }
		}
		ui.space(ui.SPACE_2)
		ui.next({width = ui.px(em * INFO_WIDTH_EM)})
		if ui.style({text_pad = 0}) { ui.paragraph(fmt.tprintf("%s###v", ui.text_shown(l.value))) }
		ui.spacer(ui.fill())
	}
	ui.space(ui.SPACE_1)
}

@(private = "file")
win_info_actions :: proc(app: ^App, em: f32) {
	cmd_button(app, "copy_all", lucide.COPY, .Info_Copy, em)
	if tool_button("read_again", lucide.REFRESH_CW, cmd_tip(.Read_Again), !information_busy(&app.information), em, Cmd.Read_Again) { refresh_now(app) }
}

info_copy :: proc(app: ^App) {
	text := info_text(info_report(app))
	platform.set_clipboard(app.main.win, text)
	n := strings.count(text, "\n")
	announce(app, fmt.tprintf(i18n.tr(n, "Copied the system's information (%d lines)", "Copied the system's information (%d lines)"), n))
}

mission_system :: proc(app: ^App, em: f32) {
	m := &app.machine
	info := app.information.data
	if info == nil { mission_note(i18n.tr("Reading…"), em); return }
	facts := [][2]string{
		{i18n.tr("Computer"), info.hostname},
		{i18n.tr("Windows"), info.build != "" ? fmt.tprintf("%s (build %s)", info.os_name, info.build) : info.os_name},
		{i18n.tr("Privilege"), info.elevated ? i18n.tr("Administrator") : i18n.tr("Standard")},
		{i18n.tr("Processor"), info.cpu.model},
		{i18n.tr("Memory"), timefmt.size(i64(m.mem.total))},
		{i18n.tr("Up for"), timefmt.stopwatch(m.uptime * 1000, {days = true})},
	}
	for f, i in facts {
		if f[1] == "" { continue }
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.7)), axis = .X, cross = .Center})
		if ui.row(.Center, {}, fmt.tprintf("###mc_sys_%d", i)) {
			ui.space(ui.SPACE_3)
			if ui.tags("weak") {
				ui.next({width = ui.px(em * 7), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###k", f[0]))
			}
			ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0, flags = {.Selectable}})
			ui.label_tip(fmt.tprintf("%s###v", ui.text_shown(f[1])))
		}
	}
	for g, i in info.gpus {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.7)), axis = .X, cross = .Center})
		if ui.row(.Center, {}, fmt.tprintf("###mc_gpu_%d", i)) {
			ui.space(ui.SPACE_3)
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
