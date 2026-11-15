// inspecteur: a task manager and system monitor for Linux (Wayland first), on gui_toolkit.
//
// One window of six sections (app.odin, view.odin): the processes, grouped into apps and background processes, sorted by
// any column, filtered as you type; the machine's performance; the services; what starts with the session; the network
// connections; what the system is. The system's side of each is in a *_linux.odin file (docs/architecture.md).
package inspecteur

import "core:fmt"
import "core:os"
import "core:strings"
import ascii "gt:ascii"
import cli "gt:cli"
import config "gt:config"
import crash "gt:crash"
import tk_log "gt:log"
import "gt:platform"
import process "gt:process"
import setup "gt:setup"

APP_VERSION :: "0.13.0"
// What changed, version by version: the settings' What's new page (in the program, beside its site's changelog).
CHANGELOG :: #load("../CHANGELOG.md", string)

USAGE :: `inspecteur: what runs on this computer

  inspecteur                  the window
  inspecteur --section name   the window, on a section: processes, performance, services, startup, connections,
                              information (the desktop entry's actions)
  inspecteur --first-frame    the window; prints when its first frame was drawn (unix time, ns) and where the
                              time went, then at the end what a sample and a frame cost (for inspecteurtool bench)
  inspecteur --demo           the window, with made-up processes, devices, services and sockets in place of the
                              system's (the pictures of the documentation: inspecteurtool shots); it acts on nothing
  inspecteur --setup          the window, the install's dialog open
  inspecteur --install        installs this copy for the user: the program, its menu entry and icons
  inspecteur --uninstall      takes the install away (the preferences stay)
  inspecteur --status         what is installed, and whether Inspecteur runs (exit 0 installed, 2 to repair,
                              1 not installed)
  inspecteur prefs            every preference, its value and what it does
  inspecteur version
  --pref name=value           a preference for this run only
`

// A section by its name in lower case ("services").
tab_of :: proc(name: string) -> (Tab, bool) {
	for t in Tab { if ascii.equal_fold(TAB_LABELS[t], name) { return t, true } }
	return .Processes, false
}

main :: proc() {
	cli.exit(run(os.args[1:]))
}

run :: proc(all_args: []string) -> cli.Exit {
	// (once, before anything reads the folders: the preferences just below, the log, the licence, the views' memory;
	// no log is open yet, so a problem goes to stderr)
	if _, why := platform.user_dirs_move(APP_NAME, APP_FOLDER); why != "" { fmt.eprintfln("inspecteur: the folders were not all moved to %s: %s", APP_FOLDER, why) }
	prefs: config.Prefs
	given, problems := prefs_open(&prefs, all_args)
	defer config.prefs_destroy(&prefs)
	for p in problems { fmt.eprintfln("inspecteur: %s", p) }
	// (--install, --uninstall and --status: no window; --setup: the window, the install's dialog open)
	cmd, rest := setup.command_of(given[:])
	if setup.command_alone(cmd) { return setup.command_run(cmd, setup_options(), process.console_write) }
	args := rest[:]
	verb := len(args) > 0 ? args[0] : ""
	switch verb {
	case "", "--first-frame", "--section", "--demo":
		// (the section shown last; --section another)
		opts := Run_Options{tab = .Processes, setup = cmd == .Setup}
		if tab, ok := tab_of(config.string_of(&prefs, "view.section")); ok { opts.tab = tab }
		for i := 0; i < len(args); i += 1 {
			switch args[i] {
			case "--first-frame": opts.first_frame = true
			case "--demo":        opts.demo = true
			case "--section":
				if i + 1 >= len(args) { fmt.eprint(USAGE); return .Usage }
				i += 1
				tab, ok := tab_of(args[i])
				if !ok { fmt.eprintfln("inspecteur: no section %s", args[i]); return .Usage }
				opts.tab = tab
			case:
				fmt.eprint(USAGE)
				return .Usage
			}
		}
		// (one Inspecteur at a time: a second start hands its section to the first, and ends)
		asked := false
		for a in args { if a == "--section" { asked = true } }
		if !opts.demo && !opts.first_frame {
			forwarded: bool
			forwarded, opts.owner, opts.owns = one_copy_acquire(opts.tab, asked)
			if forwarded { return .Done }
		}
		return app_run_kept(&prefs, opts) ? .Done : .Failed
	case "prefs":
		for name in config.sorted_names(&prefs) {
			r := config.ref_of(&prefs, name)
			e := config.entry(&prefs, r)
			fmt.printfln("%s = %s%s\n    %s", name, config.value_string(&prefs, r), config.is_default(&prefs, r) ? "" : "   (changed)", e.def.description)
		}
		return .Done
	case "version", "--version":
		fmt.printfln("inspecteur %s", APP_VERSION)
		return .Done
	case "help", "-h", "--help":
		fmt.print(USAGE)
		return .Done
	}
	fmt.eprint(USAGE)
	return .Usage
}

// The window's run, with its log (gt:log, in the state folder) and its crash reports (gt:crash): a crash leaves a report,
// which the next start says (Run_Options.last_crash). Nothing is sent anywhere.
app_run_kept :: proc(prefs: ^config.Prefs, opts: Run_Options) -> (ok: bool) {
	// (the files keep the technical name; their folders are the vendor's)
	logger := tk_log.install({program = APP_NAME, dir = tk_log.default_dir(APP_FOLDER, context.temp_allocator), echo = true})
	{
		context.logger = logger
		crash.install({program = APP_NAME, report_dir = crash.default_report_dir(APP_FOLDER, context.temp_allocator), version = APP_VERSION, log_tail = {tk_log.tail, logger.data}})
		crash.begin_session()
		o := opts
		last, crashed := crash.last_report(context.temp_allocator)
		if crashed { o.last_crash = strings.clone(last) }
		ok = app_run(prefs, o)
		delete(o.last_crash)
		crash.end_session()
	}
	tk_log.close(logger)
	return ok
}
