package inspecteur

// A service's journal on its own (Ctrl+Shift+J, or the button of the details' journal): a view per service (its
// instance names the manager and the unit: "system/foo.service", "user/foo.service", so a system service and a user
// service of the same name never share one). It opens in a window of its own, for a second screen or to keep it in
// view while the window shows another section; the system's close of that window brings it back under the Services
// table, a tab beside the details. It can float in the window, or dock elsewhere, as any view. It has its own
// Journal_View, for the service it was opened for (the details go on following the selection); the level, the boot and
// following are the preferences', as in the details. Its keys are the journal's (Ctrl+J, Alt+L, Alt+B, Alt+F, Alt+C,
// Alt+Shift+C) while it has the keyboard. Several can be open, one per service; those open at the quit open again at
// the next start, where they were.

import "core:fmt"
import "core:strings"
import "core:time"
import lucide "gt:lucide"
import "gt:ui"
import i18n "gt:i18n"

Journal_Window :: struct {
	app:     ^App,
	view:    Journal_View,
	manager: Manager,
	name:    string,   // owned: the service
	instance: string,  // owned: the view's instance, "<manager>/<service>" (journal_instance)
	drained: bool,     // closed, no reading under way, and a build of the main window since took what was posted
}

// The view's instance of the journal of `name` of `manager` (temporary allocator).
@(private = "file")
journal_instance :: proc(manager: Manager, name: string) -> string {
	return fmt.tprintf("%s/%s", MANAGER_KEYS[manager], name)
}

// The manager and the service an instance names; false when it names none (a line of another version).
@(private = "file")
journal_instance_parse :: proc(instance: string) -> (manager: Manager, name: string, ok: bool) {
	slash := strings.index_byte(instance, '/')
	if slash <= 0 || slash == len(instance) - 1 { return }
	for key, m in MANAGER_KEYS {
		if key == instance[:slash] { return m, instance[slash + 1:], true }
	}
	return
}

// Its size in a window of its own, at first (ems).
@(private = "file") JOURNAL_W_EM :: 64
@(private = "file") JOURNAL_H_EM :: 40

journal_register :: proc(app: ^App) {
	ui.view_register(&app.views, JOURNAL_VIEW, journal_window_view, ui.View_Options{
		title = i18n.later("Journal"), icon = lucide.SCROLL_TEXT,
		home = .Panel, home_place = {space = SERVICES_SPACE, edge = .Bottom}, first = .External,
		width_em = JOURNAL_W_EM, height_em = JOURNAL_H_EM, extent_em = DETAILS_EM,
	})
}

// Opens the journal of the service `name` of `manager` on its own (one already open comes forward).
journal_window_open :: proc(app: ^App, manager: Manager, name: string) {
	instance := journal_instance(manager, name)
	for w in app.journals {
		if w.instance == instance {
			ui.view_open(&app.views, JOURNAL_VIEW, w, instance = w.instance, owner = &app.main.state)
			return
		}
	}
	journal_window_new(app, manager, name)
	say(app, i18n.tr("The journal of %s on its own"), name)
}

// At start-up: the journals open at the last quit, each where it was.
journals_restore :: proc(app: ^App) {
	for instance in ui.view_restored_instances(&app.views, JOURNAL_VIEW, context.temp_allocator) {
		if manager, name, ok := journal_instance_parse(instance); ok { journal_window_new(app, manager, name) }
	}
}

// A journal of its own for the service `name` of `manager`, its reading asked, its view opened.
@(private = "file")
journal_window_new :: proc(app: ^App, manager: Manager, name: string) {
	w := new(Journal_Window)
	w.app, w.manager, w.name = app, manager, strings.clone(name)
	w.instance = strings.clone(journal_instance(manager, name))
	// (its readings are posted to the main window, whose build takes them; the view's window is built after it)
	journal_view_init(&w.view, app.demo, &app.main.state)
	journal_view_ask(&w.view, manager, name, app.settings.journal_boot)
	w.view.next = time.tick_add(time.tick_now(), JOURNAL_FOLLOW_MS * time.Millisecond)
	append(&app.journals, w)
	// (the main window owns it wherever it is opened from: it docks in the Services section of the main window)
	ui.view_open(&app.views, JOURNAL_VIEW, w, instance = w.instance, owner = &app.main.state)
}

@(private = "file")
journal_window_view :: proc(v: ^ui.View, w: ^Journal_Window) {
	app := w.app
	em := ui.font_size()
	ui.view_title(v, fmt.tprintf(i18n.tr("%s: journal"), w.name))
	if v.shown { journal_keys(app, &w.view) }
	ui.next({width = ui.fill(), height = ui.fill(), axis = .Y, bg = surface("well")})
	body := ui.build_box({.Clip, .Draw_Background}, "###jw_body")
	// (the body is the parent for the block's length)
	if ui.parent(body) {
		ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 2.2))})
		if ui.row(.Center, {}, "###jw_head") {
			ui.view_drag_handle(v, ui.parent_box())
			ui.spacer(ui.px(em * 0.8))
			if ui.tags("weak") {
				// (in a window of its own, what its commands said: the main window's footer is elsewhere)
				msg := journal_window_info(app, w)
				if v.presentation == .External && app.status != "" && ui.now_ms() < app.status_until { msg = app.status }
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label_tip(fmt.tprintf("%s###jw_info", ui.text_shown(msg)))
			}
			ui.spacer(ui.px(em * 0.4))
		}
		journal_build(app, &w.view, w.name, w.manager, true, em, in_window = true)
	}
}

// "a system service · in its state since …": its manager, and what its reading says.
@(private = "file")
journal_window_info :: proc(app: ^App, w: ^Journal_Window) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, w.manager == .System ? i18n.tr("a system service") : i18n.tr("a user service"))
	if d := w.view.details; d != nil && d.name == w.name {
		if d.since > 0 { append(&parts, fmt.tprintf(i18n.tr("in its state since %s"), started_text(app, d.since))) }
		if d.file != "" { append(&parts, d.file) }
	}
	return strings.join(parts[:], "  ·  ", context.temp_allocator)
}

// Each turn of the loop, before the frames: the journals followed are read again when due; a closed one goes once no
// reading of it is under way and the main window's build took what was posted (the reading holds its view until then).
journals_tick :: proc(app: ^App) {
	for i := len(app.journals) - 1; i >= 0; i -= 1 {
		w := app.journals[i]
		if !ui.view_is_open(&app.views, JOURNAL_VIEW, w.instance) {
			_, _ = ui.view_ended(&app.views, JOURNAL_VIEW, w.instance)   // (how it ended says nothing to do)
			ordered_remove(&app.journals, i)
			append(&app.journals_closed, w)
			continue
		}
		if app.settings.journal_follow && !app.paused && time.tick_diff(w.view.next, time.tick_now()) >= 0 && !journal_view_busy(&w.view) {
			w.view.next = time.tick_add(time.tick_now(), JOURNAL_FOLLOW_MS * time.Millisecond)
			journal_view_ask(&w.view, w.manager, w.name, app.settings.journal_boot)
		}
	}
	for i := len(app.journals_closed) - 1; i >= 0; i -= 1 {
		w := app.journals_closed[i]
		if journal_view_busy(&w.view) { w.drained = false; continue }
		// (its last reading may be posted and not taken yet: the next frame's build takes it)
		if !w.drained { w.drained = true; continue }
		unordered_remove(&app.journals_closed, i)
		journal_window_free(w)
	}
}

// The milliseconds until a journal on its own is read again (max(int): none is followed).
journals_due_ms :: proc(app: ^App) -> int {
	if !app.settings.journal_follow || app.paused { return max(int) }
	due := max(int)
	for w in app.journals { due = min(due, max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), w.view.next))) + 1, 1)) }
	if len(app.journals_closed) > 0 { due = min(due, 50) }   // (a closed one is freed at a next turn)
	return due
}

// At the end, once the chores stopped and the views were destroyed: every journal freed.
journals_destroy :: proc(app: ^App) {
	for w in app.journals { journal_window_free(w) }
	for w in app.journals_closed { journal_window_free(w) }
	delete(app.journals)
	delete(app.journals_closed)
}

@(private = "file")
journal_window_free :: proc(w: ^Journal_Window) {
	journal_view_destroy(&w.view)
	delete(w.name)
	delete(w.instance)
	free(w)
}
