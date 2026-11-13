package inspecteurtool

// desktop_files: the desktop entry and the icons of a package, as `inspecteur setup` writes them for a user (the same
// identity, actions and pictures: src/identity), under a prefix. The Nix package runs it in its installPhase.
//
//   inspecteurtool desktop_files <prefix>
//     <prefix>/share/applications/inspecteur.desktop          Exec=<prefix>/bin/inspecteur
//     <prefix>/share/icons/hicolor/<n>x<n>/apps/inspecteur.png

import "core:fmt"
import "core:os"
import desktop "gt:desktop"
import identity "../../src/identity"

run_desktop_files :: proc(args: []string) -> int {
	if len(args) != 1 { fmt.eprintln("inspecteurtool desktop_files <prefix>"); return EXIT_USAGE }
	prefix := args[0]
	o := desktop.Integration_Options{identity = identity.identity(), exe = fmt.tprintf("%s/bin/%s", prefix, identity.SLUG)}
	apps := fmt.tprintf("%s/share/applications", prefix)
	if os.make_directory_all(apps) != nil { fmt.eprintfln("inspecteurtool: %s cannot be made", apps); return 1 }
	entry := fmt.tprintf("%s/%s.desktop", apps, identity.SLUG)
	if os.write_entire_file(entry, desktop.desktop_entry_text(&o)) != nil { fmt.eprintfln("inspecteurtool: %s cannot be written", entry); return 1 }
	fmt.printfln("wrote %s", entry)
	for icon in identity.ICONS {
		dir := fmt.tprintf("%s/share/icons/hicolor/%dx%d/apps", prefix, icon.size, icon.size)
		path := fmt.tprintf("%s/%s.png", dir, identity.SLUG)
		if os.make_directory_all(dir) != nil || os.write_entire_file(path, icon.png) != nil { fmt.eprintfln("inspecteurtool: %s cannot be written", path); return 1 }
	}
	fmt.printfln("wrote %d icons under %s/share/icons/hicolor", len(identity.ICONS), prefix)
	return 0
}
