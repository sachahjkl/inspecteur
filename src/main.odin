// inspecteur: a task manager and system monitor for Linux (Wayland first), on gui_toolkit.
//
// One window of six sections (app.odin, view.odin): the processes, grouped into apps and background processes, sorted by
// any column, filtered as you type; the machine's performance; the services; what starts with the session; the network
// connections; what the system is. The system's side of each is in a *_linux.odin file (docs/architecture.md).
package inspecteur

import "core:fmt"
import "core:os"
import ascii "gt:ascii"
import config "gt:config"

APP_VERSION :: "0.3.0"

USAGE :: `inspecteur: what runs on this computer

  inspecteur                  the window
  inspecteur --section name   the window, on a section: processes, performance, services, startup, connections,
                              information (the desktop entry's actions)
  inspecteur --first-frame    the window; prints when its first frame was drawn (unix time, ns) and where the
                              time went, then at the end what a sample and a frame cost (for inspecteurtool bench)
  inspecteur --demo           the window, with made-up processes, devices, services and sockets in place of the
                              system's (the pictures of the documentation: inspecteurtool shots); it acts on nothing
  inspecteur --setup          the window, the install's dialog open
  inspecteur install          installs this copy for the user: the program, its menu entry and icons
  inspecteur uninstall        takes the install away (the preferences stay)
  inspecteur status           the install's state (exit 0 installed or a Nix package, 2 to repair, 1 not installed)
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
	os.exit(run(os.args[1:]))
}

run :: proc(all_args: []string) -> int {
	prefs: config.Prefs
	args, problems := prefs_open(&prefs, all_args)
	defer config.prefs_destroy(&prefs)
	for p in problems { fmt.eprintfln("inspecteur: %s", p) }
	verb := len(args) > 0 ? args[0] : ""
	switch verb {
	case "", "--first-frame", "--section", "--demo", "--setup":
		// (the section shown last; --section another)
		opts := Run_Options{tab = .Processes}
		if tab, ok := tab_of(config.string_of(&prefs, "view.section")); ok { opts.tab = tab }
		for i := 0; i < len(args); i += 1 {
			switch args[i] {
			case "--first-frame": opts.first_frame = true
			case "--demo":        opts.demo = true
			case "--setup":       opts.setup = true
			case "--section":
				if i + 1 >= len(args) { fmt.eprint(USAGE); return 2 }
				i += 1
				tab, ok := tab_of(args[i])
				if !ok { fmt.eprintfln("inspecteur: no section %s", args[i]); return 2 }
				opts.tab = tab
			case:
				fmt.eprint(USAGE)
				return 2
			}
		}
		// (one Inspecteur at a time: a second start hands its section to the first, and ends)
		asked := false
		for a in args { if a == "--section" { asked = true } }
		if !opts.demo && !opts.first_frame {
			forwarded: bool
			forwarded, opts.owner, opts.owns = one_copy_acquire(opts.tab, asked)
			if forwarded { return 0 }
		}
		return app_run(&prefs, opts)
	case "install":   return cmd_install()
	case "uninstall": return cmd_uninstall()
	case "status":    return cmd_status()
	case "prefs":
		for name in config.sorted_names(&prefs) {
			r := config.ref_of(&prefs, name)
			e := config.entry(&prefs, r)
			fmt.printfln("%s = %s%s\n    %s", name, config.value_string(&prefs, r), config.is_default(&prefs, r) ? "" : "   (changed)", e.def.description)
		}
		return 0
	case "version", "--version":
		fmt.printfln("inspecteur %s", APP_VERSION)
		return 0
	case "help", "-h", "--help":
		fmt.print(USAGE)
		return 0
	}
	fmt.eprint(USAGE)
	return 2
}
