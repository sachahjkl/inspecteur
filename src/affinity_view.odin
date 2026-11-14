package inspecteur

// The affinity of a process (Set affinity…, Ctrl+Shift+A, in the Processes section and the Properties): the logical
// processors it may run on, a box each. The toolkit reads and sets it on every thread of the process, pinned by its pid
// and its start time (process.affinity, process.set_affinity). A view ("affinity": views.odin), a dialog at home.

import "core:fmt"
import lucide "gt:lucide"
import process "gt:process"
import "gt:ui"
import i18n "gt:i18n"

AFFINITY_W_EM :: 30
// The processors' boxes in a row.
AFFINITY_COLUMNS :: 4

Affinity :: struct {
	target: Target,
	name:   [64]u8,
	name_len: int,
	cpus:   [process.CPU_SET_MAX]bool,
	count:  int,   // the logical processors of the machine
}

affinity_register :: proc(app: ^App) {
	ui.view_register(&app.views, AFFINITY_VIEW, affinity_view, ui.View_Options{title = i18n.later("Affinity"), icon = lucide.MICROCHIP, width_em = AFFINITY_W_EM})
}

// Reads the process's affinity (acts.odin), then opens the dialog (affinity_show); says why when it cannot be read.
affinity_open :: proc(app: ^App, p: ^Proc) {
	if app.demo != nil {
		all: process.Cpu_Set
		for i in 0 ..< min(len(app.machine.core_total), process.CPU_SET_MAX) { process.cpu_set_put(&all, i) }
		affinity_show(app, {p.pid, p.start}, p.name, all)
		return
	}
	act := act_new(.Affinity_Read, p.name)
	append(&act.targets, Target{p.pid, p.start})
	act_start(app, act)
}

// The dialog, open on the processors of `set`.
affinity_show :: proc(app: ^App, t: Target, name: string, set: process.Cpu_Set) {
	a := &app.affinity
	a.target = t
	a.name_len = copy(a.name[:], name)
	a.count = min(len(app.machine.core_total), process.CPU_SET_MAX)
	a.cpus = {}
	for i in 0 ..< a.count { a.cpus[i] = process.cpu_set_has(set, i) }
	ui.view_open(&app.views, AFFINITY_VIEW, app)
}

// The processors of `set` among the first `count`, as a list ("0-3, 8").
cpu_set_text :: proc(set: process.Cpu_Set, count: int) -> string {
	cpus := make([]bool, count, context.temp_allocator)
	for &c, i in cpus { c = process.cpu_set_has(set, i) }
	return cpu_list_text(cpus)
}

// The processors chosen, in the toolkit's set.
@(private = "file")
affinity_set :: proc(a: ^Affinity) -> (set: process.Cpu_Set, n: int) {
	for i in 0 ..< a.count {
		if a.cpus[i] { process.cpu_set_put(&set, i); n += 1 }
	}
	return
}

// The processors chosen, set (a task of the chores: acts.odin). False: none is chosen, the view stays.
@(private = "file")
affinity_apply :: proc(app: ^App) -> bool {
	a := &app.affinity
	name := fmt.tprintf(i18n.tr("%s (PID %d)"), string(a.name[:a.name_len]), a.target.pid)
	set, n := affinity_set(a)
	if n == 0 { say(app, i18n.tr("Choose at least one processor")); return false }
	if app.demo != nil { say(app, i18n.tr("The demo's processes are not the system's: nothing was changed")); return true }
	act := act_new(.Affinity_Set, name)
	append(&act.targets, a.target)
	act.set = set
	act_start(app, act)
	return true
}

// The view: which process (its title), the processors' boxes in rows, All, None, Cancel, Apply. Its rows take the room
// it has: a dialog's width, or a panel's or a window's.
@(private = "file")
affinity_view :: proc(v: ^ui.View, app: ^App) {
	a := &app.affinity
	em := ui.font_size()
	ui.view_title(v, fmt.tprintf(i18n.tr("Affinity of %s (PID %d)"), string(a.name[:a.name_len]), a.target.pid))
	if ui.dialog_body("affinity") {
		if ui.tags("weak") {
			ui.next({width = ui.fill()})
			ui.paragraph(fmt.tprintf("%s###affinity_text", i18n.tr("The logical processors it may run on: each of its threads runs on these alone.")))
		}
		rows := (a.count + AFFINITY_COLUMNS - 1) / AFFINITY_COLUMNS
		for r in 0 ..< rows {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2))})
			if ui.row(.Center, {}, fmt.tprintf("###cpus_%d", r)) {
				for c in 0 ..< AFFINITY_COLUMNS {
					i := r * AFFINITY_COLUMNS + c
					// (the last row's empty cells keep the columns in line)
					if i >= a.count { ui.spacer(ui.fill()); continue }
					ui.next({width = ui.fill(), height = ui.pct(1)})
					ui.checkbox(fmt.tprintf("###cpu_%d", i), fmt.tprintf(i18n.tr("CPU %d"), i), &a.cpus[i])
				}
			}
		}
	}
	if ui.dialog_buttons("affinity_foot") {
		if ui.button("affinity_all", i18n.tr("All")).clicked { for i in 0 ..< a.count { a.cpus[i] = true } }
		if ui.button("affinity_none", i18n.tr("None")).clicked { for i in 0 ..< a.count { a.cpus[i] = false } }
		if ui.button("affinity_cancel", i18n.tr("Cancel")).clicked { ui.view_end(v, ui.VIEW_CANCELLED) }
		if ui.button("affinity_apply", i18n.tr("Apply (Enter)"), o = {intent = .Primary}).clicked || v.shown && ui.key_press(.Return) {
			if affinity_apply(app) { ui.view_end(v, 0) }
		}
	}
}
