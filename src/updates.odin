package inspecteur

// Updates: gui_toolkit's (prefs_page.updates_*, over gt:update: its docs/update.md and docs/prefs_page.md) check
// inspecteur's latest release a while after the start and then every day, download the program it names, check it
// against its signed manifest (src/update: inspecteur's product and key) and put it in place of this one. Only the
// installed copy does it by itself (update.auto, applied as the install's reading comes in): a build, or a copy run where
// it was unpacked, is updated when the settings' Check now asks. The new program runs at the next start, or at once from
// the settings' Restart now. A copy from the Nix store is left to Nix; the demo checks nothing. What is inspecteur's here:
// its words in the status bar, and its restart.

import "gt:host"
import "gt:platform"
import prefs_page "gt:prefs_page"
import update "gt:update"
import inspecteur_update "update"

// At the start, once the window is open (its chores write the installed copy's manifest; the updater's news wakes it).
// Nothing is checked before the install's reading says this copy is the installed one, or before Check now.
updates_start :: proc(app: ^App) {
	if app.demo != nil { return }
	prefs_page.updates_start(&app.updates, {
		product = inspecteur_update.PRODUCT, repository = "sachahjkl/inspecteur", version = APP_VERSION,
		prefs = &app.prefs, install = &app.install, state = &app.main.state, window = app.main.win,
	})
}

// At each turn of the loop: the footer's badge shows the phase (a version on offer, its download, a restart); the
// footer's message says only what the badge cannot (update.notice), once.
updates_follow :: proc(app: ^App) {
	changed, st := prefs_page.updates_follow(&app.updates)
	if !changed { return }
	host.host_settle(&app.main)   // (the badge and the settings show the state)
	if words, _ := update.notice(st); words != "" { say(app, "%s", words) }
}

// The new program takes over: started once this one has ended.
updates_restart :: proc(app: ^App) {
	app.restart = true
	platform.request_close(app.main.win)
}
