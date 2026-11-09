// inspecteur: a system monitor for Linux (Wayland first), on gui_toolkit.
//
// One window: the processes read from /proc each second, grouped into apps and background processes, sorted by any
// column, filtered as you type (app.odin, view.odin).
package inspecteur

import "core:fmt"
import "core:os"
import config "gt:config"

APP_VERSION :: "0.1.0"

USAGE :: `inspecteur: the processes of the system

  inspecteur                  the window
  inspecteur --first-frame    the window; prints when its first frame was drawn (unix time, ns) and where the
                              time went, then at the end what a sample and a frame cost (for inspecteurtool bench)
  inspecteur prefs            every preference, its value and what it does
  inspecteur version
  --pref name=value           a preference for this run only
`

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
	case "", "--first-frame":
		return app_run(&prefs, first_frame = verb == "--first-frame")
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
