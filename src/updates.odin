package inspecteur

// Updates: gui_toolkit's Updater (gt:update, its docs/update.md) checks inspecteur's latest release a while after the
// start and then every day, downloads the program it names, checks it against its signed manifest (src/update:
// inspecteur's product and key) and puts it in place of this one. Only the installed copy does it by itself (update.auto):
// a build, or a copy run where it was unpacked, is updated when the settings' Check now asks. The new program runs at the
// next start, or at once from the settings' Restart now. A copy from the Nix store is left to Nix; the demo checks nothing.

import "core:fmt"
import "core:log"
import "core:strings"
import "gt:platform"
import "gt:ui"
import setup "gt:setup"
import update "gt:update"
import inspecteur_update "update"

// The folder of the latest release's files: its manifest (update-<platform>.json and .sig) and its program.
UPDATE_FOLDER :: "https://github.com/sachahjkl/inspecteur/releases/latest/download/"

// Once the setup's facts are read (setup_offer): `installed`, this program is the installed copy; `exe`, its path.
updates_start :: proc(app: ^App, installed: bool, exe: string) {
	if app.demo != nil || app.updater != nil { return }
	app.installed_copy = installed
	app.updater = update.updater_start({
		product = inspecteur_update.PRODUCT, folder = UPDATE_FOLDER, current = APP_VERSION,
		exe = exe, user_agent = fmt.tprintf("inspecteur/%s", APP_VERSION),
		// (the updater's thread: the loop wakes, and updates_follow reads the state)
		news = proc(user: rawptr) { platform.wake((^App)(user).main.win) }, user = app,
	})
	updates_auto(app)
}

// update.auto, read again when the preferences change.
updates_auto :: proc(app: ^App) {
	if app.updater == nil { return }
	auto := app.settings.update_auto && app.installed_copy
	update.set_auto(app.updater, check = auto, install = auto)
}

// At each turn of the loop: what changed is said in the footer.
updates_follow :: proc(app: ^App) {
	if app.updater == nil { return }
	st := update.status(app.updater)
	if st.serial == app.update_serial { return }
	app.update_serial = st.serial
	app.main.settle = max(app.main.settle, FRAMES_AFTER_INPUT)   // (the settings show the state)
	// (said when asked, or when there is something to know: not each check that found nothing)
	if st.asked || st.phase == .Installed || st.phase == .Available { say(app, "%s", update.status_words(st)) }
	// (the installed copy: its manifest says the new version; written by a task of the chores)
	if st.phase == .Installed {
		version := new(string)
		version^ = strings.clone(st.version)
		ui.task(&app.main.state, manifest_work, nil, version, version_free)
	}
}

// The installed copy's manifest gets the new version (`data`: a ^string, owned).
@(private = "file")
manifest_work :: proc(data: rawptr) {
	defer version_free(data)
	if ok, why := setup.updated(setup_config(), (^string)(data)^); !ok { log.errorf("the update is in place, but %s", why) }
}

@(private = "file")
version_free :: proc(data: rawptr) {
	v := (^string)(data)
	delete(v^)
	free(v)
}

// The new program takes over: started once this one has ended.
updates_restart :: proc(app: ^App) {
	app.restart = true
	platform.request_close(app.main.win)
}

updates_stop :: proc(app: ^App) {
	if app.updater != nil { update.updater_stop(app.updater) }
}
