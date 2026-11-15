package inspecteur

// What Inspecteur does to processes, off the window's thread: a signal, a suspend or a resume, a priority, an affinity
// read or set. gt:process pins each process by a pidfd and reads its start time again before it acts: system calls,
// which can wait. The window asks (act_start), a task of the chores acts, and the window says what came of it at its
// next build (act_done).

import "core:strings"
import process "gt:process"
import "gt:ui"
import i18n "gt:i18n"

Act_Kind :: enum u8 {
	Signal,          // `sig` to every target
	Suspend,         // the target stopped when it runs, resumed when it is stopped (its state read now)
	Priority,        // the target's nice value set to `nice`
	Affinity_Read,   // the target's affinity read, then the dialog opens
	Affinity_Set,    // the target's affinity set to `set`
}

Act :: struct {
	kind:    Act_Kind,
	name:    string,            // owned: what the footer calls it ("sleep (PID 12)")
	targets: [dynamic]Target,
	owners:  [dynamic]string,   // Signal: each target's owner (the reader's names, which outlive the act)
	sig:     process.Signal,
	guard:   Guard,             // Suspend: what the process is to Inspecteur (it is not stopped unless None)
	nice:    i8,
	set:     process.Cpu_Set,
	// what came of it
	result:  process.Act_Result,
	errno:   int,
	sent:    int,
	owner:   string,            // Signal: the owner of a process that refused
	guarded: bool,              // Suspend: not stopped, for its guard
}

// Hands `a` (heap; act_new) to the chores.
act_start :: proc(app: ^App, a: ^Act) {
	ui.task(&app.main.state, act_work, act_done, a, act_lost)
}

act_new :: proc(kind: Act_Kind, name: string) -> ^Act {
	a := new(Act)
	a.kind, a.name = kind, strings.clone(name)
	return a
}

@(private = "file")
act_free :: proc(a: ^Act) {
	delete(a.name)
	delete(a.targets)
	delete(a.owners)
	free(a)
}

@(private = "file")
act_lost :: proc(data: rawptr) { act_free((^Act)(data)) }

@(private = "file")
act_work :: proc(data: rawptr) {
	a := (^Act)(data)
	switch a.kind {
	case .Signal:
		for t, i in a.targets {
			#partial switch r, e := process.signal_process(t.pid, t.start, a.sig); r {
			case .Done: a.sent += 1
			case .Gone:   // (it ended in between)
			case:
				a.result, a.errno = r, e
				a.owner = a.owners[i]
			}
		}
	case .Suspend:
		t := a.targets[0]
		// (the state now, not the last sample's: the process may have been resumed since)
		if proc_state_now(t.pid, t.start) == .Stopped {
			a.sig = .Continue
		} else if a.guard != .None {
			a.sig, a.guarded = .Stop, true
			return
		} else {
			a.sig = .Stop
		}
		r, e := process.signal_process(t.pid, t.start, a.sig)
		if r == .Done { a.sent = 1 } else if r != .Gone { a.result, a.errno = r, e }
	case .Priority:
		a.result, a.errno = process.set_priority(a.targets[0].pid, a.targets[0].start, int(a.nice))
	case .Affinity_Read:
		a.set, a.result, a.errno = process.affinity(a.targets[0].pid, a.targets[0].start)
	case .Affinity_Set:
		a.result, a.errno = process.set_affinity(a.targets[0].pid, a.targets[0].start, a.set)
	}
}

// On the window's thread: what the act came to, said; the rows show it before the next sample.
@(private = "file")
act_done :: proc(data: rawptr, _: u64) {
	a := (^Act)(data)
	defer act_free(a)
	app := the_app
	if app == nil { return }
	switch a.kind {
	case .Signal, .Suspend: signal_said(app, a)
	case .Priority:
		#partial switch a.result {
		case .Gone:
			say(app, i18n.tr("%s has ended already"), a.name)
		case .Done:
			say(app, i18n.tr("%s now runs at %s"), a.name, priority_text(a.nice))
			if p := find_proc(&app.sampler, a.targets[0].pid, a.targets[0].start); p != nil { p.nice = a.nice }
			sample_soon(app)
		case .Denied:
			say(app, i18n.tr("Access denied: %s"), i18n.tr(PRIORITY_DENIED))
		case:
			say(app, i18n.tr("The priority of %s cannot be changed"), a.name)
		}
	case .Affinity_Read:
		#partial switch a.result {
		case .Done:   affinity_show(app, a.targets[0], a.name, a.set)
		case .Gone:   say(app, i18n.tr("%s has ended already"), a.name)
		case .Denied: say(app, i18n.tr("Access denied: %s is another user's process"), a.name)
		case:         say(app, i18n.tr("The affinity of %s cannot be read"), a.name)
		}
	case .Affinity_Set:
		#partial switch a.result {
		case .Done:   say(app, i18n.tr("%s runs on %s now"), a.name, cpu_set_text(a.set, min(len(app.machine.core_total), process.CPU_SET_MAX)))
		case .Gone:   say(app, i18n.tr("%s has ended already"), a.name)
		case .Denied: say(app, i18n.tr("Access denied: only its owner, or %s, may change the affinity of %s"), ADMIN, a.name)
		case:         say(app, i18n.tr("The affinity of %s cannot be changed"), a.name)
		}
	}
}

// What a signal came to. A suspended process is shown suspended at once, before the next sample.
@(private = "file")
signal_said :: proc(app: ^App, a: ^Act) {
	if a.guarded {
		switch a.guard {
		case .None:
		case .Self:           say(app, i18n.tr("Inspecteur does not suspend itself: nothing could resume it"))
		case .Ancestor:       say(app, i18n.tr("%s runs Inspecteur: suspended, it would stop Inspecteur too"), a.name)
		case .Display_Server: say(app, i18n.tr("%s draws the desktop: suspended, it would freeze every window, this one too"), a.name)
		}
		return
	}
	// (a sentence per verb: a language words each its own way)
	denied, failed := i18n.tr("%s is %s's: Inspecteur may not end it (only its owner, or %s, may)"), i18n.tr("%s cannot be ended (error %d)")
	#partial switch a.sig {
	case .Stop:
		denied, failed = i18n.tr("%s is %s's: Inspecteur may not suspend it (only its owner, or %s, may)"), i18n.tr("%s cannot be suspended (error %d)")
	case .Continue:
		denied, failed = i18n.tr("%s is %s's: Inspecteur may not resume it (only its owner, or %s, may)"), i18n.tr("%s cannot be resumed (error %d)")
	}
	switch {
	case a.result == .Denied:
		say(app, denied, a.name, a.owner, ADMIN)
	case a.result != .Done:
		say(app, failed, a.name, a.errno)
	case a.sent > 0:
		#partial switch a.sig {
		case .Kill:     say(app, i18n.tr("Killed %s"), a.name)
		case .Stop:     say(app, i18n.tr("Suspended %s"), a.name)
		case .Continue: say(app, i18n.tr("Resumed %s"), a.name)
		case:           say(app, i18n.tr("Asked %s to end"), a.name)
		}
	case:
		say(app, i18n.tr("%s has ended already"), a.name)
	}
	if a.sent == 0 { return }
	#partial switch a.sig {
	case .Stop, .Continue:
		for t in a.targets {
			if p := find_proc(&app.sampler, t.pid, t.start); p != nil { p.state = a.sig == .Stop ? .Stopped : .Sleeping }
		}
	}
	sample_soon(app)
}
