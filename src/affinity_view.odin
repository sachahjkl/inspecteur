package inspecteur

// The affinity of a process (Set affinity…, Ctrl+Shift+A, in the Processes section and the Properties): the logical
// processors it may run on, a box each. The toolkit reads and sets it on every thread of the process, pinned by its pid
// and its start time (process.affinity, process.set_affinity).

import "core:fmt"
import process "gt:process"
import "gt:ui"

AFFINITY_W_EM :: 30
// The processors' boxes in a row.
AFFINITY_COLUMNS :: 4

Affinity :: struct {
	open:   bool,
	target: Target,
	name:   [64]u8,
	name_len: int,
	cpus:   [process.CPU_SET_MAX]bool,
	count:  int,   // the logical processors of the machine
}

// Reads the process's affinity and opens the dialog; says why when it cannot be read.
affinity_open :: proc(app: ^App, p: ^Proc) {
	a := &app.affinity
	a.target = {p.pid, p.start}
	a.name_len = copy(a.name[:], p.name)
	a.count = min(len(app.machine.core_total), process.CPU_SET_MAX)
	a.cpus = {}
	if app.demo != nil {
		for i in 0 ..< a.count { a.cpus[i] = true }
	} else {
		set, r, _ := process.affinity(p.pid, p.start)
		#partial switch r {
		case .Done:
		case .Gone:   say(app, "%s has ended already", p.name); return
		case .Denied: say(app, "Access denied: %s is another user's process", p.name); return
		case:         say(app, "The affinity of %s cannot be read", p.name); return
		}
		for i in 0 ..< a.count { a.cpus[i] = process.cpu_set_has(set, i) }
	}
	a.open = true
}

// The processors chosen, in the toolkit's set.
@(private = "file")
affinity_set :: proc(a: ^Affinity) -> (set: process.Cpu_Set, n: int) {
	for i in 0 ..< a.count {
		if a.cpus[i] { process.cpu_set_put(&set, i); n += 1 }
	}
	return
}

@(private = "file")
affinity_apply :: proc(app: ^App) {
	a := &app.affinity
	name := fmt.tprintf("%s (PID %d)", string(a.name[:a.name_len]), a.target.pid)
	set, n := affinity_set(a)
	if n == 0 { say(app, "Choose at least one processor"); return }
	a.open = false
	if app.demo != nil { say(app, "The demo's processes are not the system's: nothing was changed"); return }
	#partial switch r, _ := process.set_affinity(a.target.pid, a.target.start, set); r {
	case .Done:   say(app, "%s runs on %s now", name, cpu_list_text(a.cpus[:a.count]))
	case .Gone:   say(app, "%s has ended already", name)
	case .Denied: say(app, "Access denied: only its owner, or %s, may change the affinity of %s", ADMIN, name)
	case:         say(app, "The affinity of %s cannot be changed", name)
	}
}

affinity_build :: proc(app: ^App, em: f32) {
	a := &app.affinity
	w := em * AFFINITY_W_EM
	if ui.modal("affinity", w, &a.open) {
		pad := em * 1.2
		ui.next({width = ui.px(w), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###affinity") {
			ui.spacer(ui.px(pad))
			line :: proc(id_text: string, w, pad: f32, weak := false, size: f32 = 0) {
				ui.next({width = ui.px(w), height = ui.children_sum()})
				if ui.row(.Start, {}, fmt.tprintf("###row%s", id_text)) {
					ui.spacer(ui.px(pad))
					if weak { ui.push_tags("weak") }
					ui.next({width = ui.px(w - 2 * pad), font_size = size > 0 ? size : nil})
					ui.paragraph(id_text)
					if weak { ui.pop_tags() }
				}
			}
			line(fmt.tprintf("Affinity of %s (PID %d)###affinity_title", ui.text_shown(string(a.name[:a.name_len])), a.target.pid), w, pad, size = em * 1.15)
			ui.spacer(ui.px(em * 0.4))
			line("The logical processors it may run on: each of its threads runs on these alone.###affinity_text", w, pad, weak = true)
			ui.spacer(ui.px(em * 0.8))
			rows := (a.count + AFFINITY_COLUMNS - 1) / AFFINITY_COLUMNS
			cell_w := (w - 2 * pad) / AFFINITY_COLUMNS
			for r in 0 ..< rows {
				ui.next({width = ui.px(w), height = ui.px(ui.dense(em * 2))})
				if ui.row(.Center, {}, fmt.tprintf("###cpus_%d", r)) {
					ui.spacer(ui.px(pad))
					for c in 0 ..< AFFINITY_COLUMNS {
						i := r * AFFINITY_COLUMNS + c
						if i >= a.count { break }
						ui.next({width = ui.px(cell_w), height = ui.pct(1)})
						ui.checkbox(fmt.tprintf("###cpu_%d", i), fmt.tprintf("CPU %d", i), &a.cpus[i])
					}
				}
			}
			ui.spacer(ui.px(em * 0.8))
			ui.next({width = ui.px(w), height = ui.children_sum()})
			if ui.row(.Center, {}, "###affinity_foot") {
				ui.spacer(ui.px(pad))
				ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
				if ui.button("All###affinity_all").clicked { for i in 0 ..< a.count { a.cpus[i] = true } }
				ui.spacer(ui.px(em * 0.4))
				ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
				if ui.button("None###affinity_none").clicked { for i in 0 ..< a.count { a.cpus[i] = false } }
				ui.spacer(ui.fill())
				ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
				if ui.button("Cancel###affinity_cancel").clicked { a.open = false }
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.text_size(em * 1.2), height = ui.px(ui.dense(em * 2.2))})
				if ui.tags("accent_button") {
					if ui.button("Apply (Enter)###affinity_apply").clicked || ui.key_press(.Return) { affinity_apply(app) }
				}
				ui.spacer(ui.px(pad))
			}
			ui.spacer(ui.px(pad))
		}
	}
}
