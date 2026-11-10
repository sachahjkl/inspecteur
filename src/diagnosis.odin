package inspecteur

// "Why is it slow?" (F2): what the last sample says of the machine, in sentences, the worst first: the processors and
// who keeps them busy, the time tasks waited (pressure), the memory and the swap, the disks, the GPU, the heat. Read from
// the machine and the processes already sampled: nothing is read for it.

import "core:fmt"
import "core:slice"
import "gt:ui"

// When a part counts as busy: past WARN it is said, past BAD it is the cause.
DIAG_CPU_WARN, DIAG_CPU_BAD           :: f32(60), f32(90)       // percent of the machine
DIAG_PRESSURE_WARN, DIAG_PRESSURE_BAD :: f32(10), f32(30)       // percent of the last 10 s some task waited
DIAG_MEM_WARN, DIAG_MEM_BAD           :: f64(0.80), f64(0.92)   // share of the memory in use
DIAG_SWAP_WARN                        :: f64(0.25)              // share of the swap in use
DIAG_DISK_WARN, DIAG_DISK_BAD         :: f32(60), f32(90)       // percent of the time a disk was busy
DIAG_GPU_WARN                         :: f32(90)
DIAG_HOT_C                            :: f32(85)
// How many of the busiest processes a finding names.
DIAG_TOP :: 3
DIAG_W_EM :: 34

Finding_Level :: enum u8 { Fine, Warn, Bad }

Finding :: struct {
	level: Finding_Level,
	text:  string,   // temporary allocator
}

// What the machine says now, the worst first; one Fine finding when nothing stands out.
diagnose :: proc(app: ^App) -> []Finding {
	m := &app.machine
	out := make([dynamic]Finding, context.temp_allocator)
	add :: proc(out: ^[dynamic]Finding, level: Finding_Level, format: string, args: ..any) {
		append(out, Finding{level, fmt.tprintf(format, ..args)})
	}

	if m.cpu >= DIAG_CPU_WARN {
		add(&out, m.cpu >= DIAG_CPU_BAD ? .Bad : .Warn, "The processors are %.0f%% busy. The busiest: %s.", m.cpu, busiest(app, .Cpu))
	}
	if m.has_pressure {
		NAMES := [Pressure_Kind]string{.Cpu = "a processor", .Memory = "memory", .Io = "the disks"}
		for k in Pressure_Kind {
			p := m.pressure[k].some10
			if p >= DIAG_PRESSURE_WARN {
				add(&out, p >= DIAG_PRESSURE_BAD ? .Bad : .Warn, "Tasks waited for %s %.0f%% of the last 10 seconds.", NAMES[k], p)
			}
		}
	}
	if m.mem.total > 0 {
		used := f64(m.mem.total - min(m.mem.available, m.mem.total)) / f64(m.mem.total)
		if used >= DIAG_MEM_WARN {
			add(&out, used >= DIAG_MEM_BAD ? .Bad : .Warn, "The memory is %.0f%% in use (%s of %s). The largest: %s.", used * 100, size_text(m.mem.total - m.mem.available), size_text(m.mem.total), busiest(app, .Memory))
		}
	}
	if m.mem.swap_total > 0 {
		swapped := f64(m.mem.swap_total - min(m.mem.swap_free, m.mem.swap_total)) / f64(m.mem.swap_total)
		if swapped >= DIAG_SWAP_WARN {
			add(&out, .Warn, "%s of the swap is in use: pages wait on the disk.", size_text(m.mem.swap_total - m.mem.swap_free))
		}
	}
	for &d in m.disks {
		if d.active >= DIAG_DISK_WARN {
			add(&out, d.active >= DIAG_DISK_BAD ? .Bad : .Warn, "The disk %s is busy %.0f%% of the time. Reading and writing the most: %s.", d.name, d.active, busiest(app, .Disk))
		}
	}
	for &g in m.gpus {
		if g.read.has_util && g.read.util >= DIAG_GPU_WARN {
			add(&out, .Warn, "The GPU %s is %.0f%% busy.", gpu_name(&g.read), g.read.util)
		}
	}
	if m.temp_count > 0 && m.temps[0].celsius >= DIAG_HOT_C {
		add(&out, .Warn, "The processor is hot: %.0f °C.", m.temps[0].celsius)
	}
	if m.throttled > m.throttled_before {
		add(&out, .Bad, "The processor slowed for its heat %d times since Inspecteur started.", m.throttled - m.throttled_before)
	}
	if len(out) == 0 {
		add(&out, .Fine, "Nothing stands out: the processors are %.0f%% busy and the memory has room.", m.cpu)
	}
	slice.stable_sort_by(out[:], proc(a, b: Finding) -> bool { return a.level > b.level })
	return out[:]
}

@(private = "file")
Busy_By :: enum u8 { Cpu, Memory, Disk }

// The DIAG_TOP busiest processes by `by`, "name (value)" apart by commas; "none" when no process uses any.
@(private = "file")
busiest :: proc(app: ^App, by: Busy_By) -> string {
	value :: proc(p: ^Proc, by: Busy_By) -> f64 {
		switch by {
		case .Cpu:    return f64(p.cpu)
		case .Memory: return f64(p.private)
		case .Disk:   return p.read_rate + p.write_rate
		}
		return 0
	}
	order := make([dynamic]^Proc, context.temp_allocator)
	for &p in app.sampler.procs { if !p.ended && value(&p, by) > 0 { append(&order, &p) } }
	slice.sort_by(order[:], proc(a, b: ^Proc) -> bool { return a.cpu > b.cpu })
	switch by {
	case .Cpu:
	case .Memory: slice.sort_by(order[:], proc(a, b: ^Proc) -> bool { return a.private > b.private })
	case .Disk:   slice.sort_by(order[:], proc(a, b: ^Proc) -> bool { return a.read_rate + a.write_rate > b.read_rate + b.write_rate })
	}
	if len(order) == 0 { return "none" }
	parts := make([dynamic]string, context.temp_allocator)
	for p in order[:min(DIAG_TOP, len(order))] {
		shown: string
		switch by {
		case .Cpu:    shown = fmt.tprintf("%.0f%%", p.cpu)
		case .Memory: shown = size_text(p.private)
		case .Disk:   shown = fmt.tprintf("%s/s", size_text(u64(p.read_rate + p.write_rate)))
		}
		append(&parts, fmt.tprintf("%s (%s)", p.name, shown))
	}
	return join_comma(parts[:])
}

@(private = "file")
join_comma :: proc(parts: []string) -> string {
	out := ""
	for p, i in parts { out = i == 0 ? p : fmt.tprintf("%s, %s", out, p) }
	return out
}

// The dialog: the findings, each after a dot in the colour of its level.
diagnosis_build :: proc(app: ^App, em: f32) {
	w := em * DIAG_W_EM
	// (the dialog ends with this if's block: modal_end is deferred to it)
	if ui.modal("diagnosis", w, &app.diagnosis_open) {
		pad := em * 1.4
		ui.next({width = ui.px(w), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###diagnosis") {
			ui.spacer(ui.px(pad))
			ui.next({width = ui.px(w), height = ui.children_sum()})
			if ui.row(id = "###diag_head") {
				ui.spacer(ui.px(pad))
				ui.next({width = ui.fill(), font_size = em * 1.4})
				ui.paragraph("Why is it slow?###diag_title")
				ui.spacer(ui.px(pad))
			}
			ui.spacer(ui.px(em * 0.8))
			for f, i in diagnose(app) {
				ui.next({width = ui.px(w), height = ui.children_sum(), cross = .Start})
				if ui.row(id = fmt.tprintf("###diag_row%d", i)) {
					ui.spacer(ui.px(pad))
					heat := f.level == .Bad ? f32(1) : f.level == .Warn ? f32(0.55) : f32(0)
					ui.next({width = ui.px(em * 0.7), height = ui.px(em * 0.7), radius = em * 0.35, bg = heat_hue(heat)})
					ui.build_box({.Draw_Background}, fmt.tprintf("###diag_dot%d", i))
					ui.spacer(ui.px(em * 0.6))
					ui.next({width = ui.fill()})
					ui.paragraph(fmt.tprintf("%s###diag_text%d", f.text, i))
					ui.spacer(ui.px(pad))
				}
				ui.spacer(ui.px(em * 0.5))
			}
			ui.spacer(ui.px(em * 0.6))
			ui.next({width = ui.px(w), height = ui.children_sum()})
			if ui.row(id = "###diag_foot") {
				ui.spacer(ui.fill())
				if ui.button("Close###diag_close").clicked { app.diagnosis_open = false }
				ui.spacer(ui.px(pad))
			}
			ui.spacer(ui.px(pad))
		}
	}
}
