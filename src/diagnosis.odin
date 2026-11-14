package inspecteur

// "Why is it slow?" (F2): what the last sample says of the machine, in sentences, the worst first: the processors and
// who keeps them busy, the time tasks waited (pressure), the memory and the swap, the disks, the GPU, the heat. Read from
// the machine and the processes already sampled: nothing is read for it. A view ("diagnosis": views.odin), a dialog at
// home.

import "core:fmt"
import "core:slice"
import lucide "gt:lucide"
import "gt:ui"
import i18n "gt:i18n"

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
		add(&out, m.cpu >= DIAG_CPU_BAD ? .Bad : .Warn, i18n.tr("The processors are %.0f%% busy. The busiest: %s."), m.cpu, busiest(app, .Cpu))
	}
	if m.has_pressure {
		// (a sentence per resource: a language words each its own way)
		sentences := [Pressure_Kind]string{
			.Cpu = i18n.tr("Tasks waited for a processor %.0f%% of the last 10 seconds."),
			.Memory = i18n.tr("Tasks waited for memory %.0f%% of the last 10 seconds."),
			.Io = i18n.tr("Tasks waited for the disks %.0f%% of the last 10 seconds."),
		}
		for k in Pressure_Kind {
			p := m.pressure[k].some10
			if p >= DIAG_PRESSURE_WARN {
				add(&out, p >= DIAG_PRESSURE_BAD ? .Bad : .Warn, sentences[k], p)
			}
		}
	}
	if m.mem.total > 0 {
		used := f64(m.mem.total - min(m.mem.available, m.mem.total)) / f64(m.mem.total)
		if used >= DIAG_MEM_WARN {
			add(&out, used >= DIAG_MEM_BAD ? .Bad : .Warn, i18n.tr("The memory is %.0f%% in use (%s of %s). The largest: %s."), used * 100, size_text(m.mem.total - m.mem.available), size_text(m.mem.total), busiest(app, .Memory))
		}
	}
	if m.mem.swap_total > 0 {
		swapped := f64(m.mem.swap_total - min(m.mem.swap_free, m.mem.swap_total)) / f64(m.mem.swap_total)
		if swapped >= DIAG_SWAP_WARN {
			add(&out, .Warn, i18n.tr("%s of the swap is in use: pages wait on the disk."), size_text(m.mem.swap_total - m.mem.swap_free))
		}
	}
	for &d in m.disks {
		if d.active >= DIAG_DISK_WARN {
			add(&out, d.active >= DIAG_DISK_BAD ? .Bad : .Warn, i18n.tr("The disk %s is busy %.0f%% of the time. Reading and writing the most: %s."), d.name, d.active, busiest(app, .Disk))
		}
	}
	for &g in m.gpus {
		if g.read.has_util && g.read.util >= DIAG_GPU_WARN {
			add(&out, .Warn, i18n.tr("The GPU %s is %.0f%% busy."), gpu_name(&g.read), g.read.util)
		}
	}
	if m.temp_count > 0 && m.temps[0].celsius >= DIAG_HOT_C {
		add(&out, .Warn, i18n.tr("The processor is hot: %.0f °C."), m.temps[0].celsius)
	}
	if m.throttled > m.throttled_before {
		n := int(m.throttled - m.throttled_before)
		add(&out, .Bad, i18n.tr(n, "The processor slowed for its heat %d time since inspecteur started.", "The processor slowed for its heat %d times since inspecteur started."), n)
	}
	if len(out) == 0 {
		add(&out, .Fine, i18n.tr("Nothing stands out: the processors are %.0f%% busy and the memory has room."), m.cpu)
	}
	slice.stable_sort_by(out[:], proc(a, b: Finding) -> bool { return a.level > b.level })
	return out[:]
}

// A measure the processes are ranked by.
Busy_By :: enum u8 { Cpu, Memory, Disk }

// The processes ranked: the BUSIEST_KEEP that use the most of each measure (indices into the sampler's processes, the
// most first; those that ended left out), and the threads of them all. Made at each sample (sample_take), so that a
// view reads them at each frame without a pass over every process.
Ranking :: struct {
	busiest: [Busy_By][dynamic]int,
	threads: i32,
}

// The processes kept of each ranking: Mission Control's lists are the longest.
BUSIEST_KEEP :: 8

busy_value :: proc(p: ^Proc, by: Busy_By) -> f64 {
	switch by {
	case .Cpu:    return f64(p.cpu)
	case .Memory: return f64(p.private)
	case .Disk:   return p.read_rate + p.write_rate
	}
	return 0
}

ranking_make :: proc(app: ^App) {
	r := &app.ranking
	r.threads = 0
	for p in app.sampler.procs { r.threads += p.threads }
	order := make([dynamic]int, 0, len(app.sampler.procs), context.temp_allocator)
	for by in Busy_By {
		clear(&order)
		for &p, i in app.sampler.procs { if !p.ended { append(&order, i) } }
		context.user_index = int(by)
		// (the measure through the context: a procedure literal takes nothing from its scope)
		slice.sort_by(order[:], proc(a, b: int) -> bool {
			measure := Busy_By(context.user_index)
			return busy_value(&the_app.sampler.procs[a], measure) > busy_value(&the_app.sampler.procs[b], measure)
		})
		clear(&r.busiest[by])
		append(&r.busiest[by], ..order[:min(len(order), BUSIEST_KEEP)])
	}
}

ranking_destroy :: proc(r: ^Ranking) {
	for &l in r.busiest { delete(l) }
}

// The DIAG_TOP busiest processes by `by`, "name (value)" apart by commas; "none" when no process uses any.
@(private = "file")
busiest :: proc(app: ^App, by: Busy_By) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for i in app.ranking.busiest[by] {
		p := &app.sampler.procs[i]
		if len(parts) == DIAG_TOP || busy_value(p, by) <= 0 { break }
		shown: string
		switch by {
		case .Cpu:    shown = percent_text(f64(p.cpu))
		case .Memory: shown = size_text(p.private)
		case .Disk:   shown = fmt.tprintf("%s/s", size_text(u64(p.read_rate + p.write_rate)))
		}
		append(&parts, fmt.tprintf("%s (%s)", p.name, shown))
	}
	if len(parts) == 0 { return i18n.tr("none") }
	return join_comma(parts[:])
}

@(private = "file")
join_comma :: proc(parts: []string) -> string {
	out := ""
	for p, i in parts { out = i == 0 ? p : fmt.tprintf("%s, %s", out, p) }
	return out
}

diagnosis_register :: proc(app: ^App) {
	ui.view_register(&app.views, DIAGNOSIS_VIEW, diagnosis_view, ui.View_Options{title = i18n.later("Why is it slow?"), icon = lucide.LIGHTBULB, width_em = DIAG_W_EM})
}

// "Why is it slow?" (F2, the Health panel's (i)): one already open comes forward.
diagnosis_open :: proc(app: ^App) { ui.view_open(&app.views, DIAGNOSIS_VIEW, app) }

// The view: the findings, each after a dot in the colour of its level. Its rows take the room it has: a dialog's width,
// or a panel's or a window's.
@(private = "file")
diagnosis_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	pad := em * 1.4
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
	if ui.column(id = "###diagnosis") {
		ui.spacer(ui.px(em * 0.8))
		for f, i in diagnose(app) {
			ui.next({width = ui.fill(), height = ui.children_sum(), cross = .Start})
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
	}
	if ui.dialog_buttons("diag_foot") {
		if ui.button("diag_close", i18n.tr("Close")).clicked { ui.view_end(v, 0) }
	}
}
