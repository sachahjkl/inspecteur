// inspecteurtool: the project's machinery, one program, whatever the shell.
//
//   odin run tools/inspecteurtool -collection:gt=ext/gui_toolkit/src -out:build/inspecteurtool -- <command>
//   (build.sh and build.bat are its shortcuts for `build`)
//
// What it needs is on the path: git, odin, cargo (the toolkit's text library); sway for live, shots and bench.
// GT=<folder>: another checkout of gui_toolkit (its root, not its src).
package inspecteurtool

import "core:fmt"
import "core:os"
import "core:strings"
import toolbox "gt:toolbox"

EXIT_USAGE :: 2
ROOT_MARK  :: "odin.version"

Command :: struct {
	name, about: string,
	run:         proc(args: []string) -> int,
}

COMMANDS :: [?]Command{
	{name = "build", about = "[release]: the toolkit's text library when its sources changed, then build/inspecteur", run = run_build},
	{name = "test", about = "the unit tests of the program", run = run_test},
	{name = "check", about = "odin check of the program and of this tool (-vet), the tests, then a release build", run = run_check},
	{name = "live", about = "[--keep]: the real program in a sway nobody sees: rows, filter, sort, menu, End task and Kill on its own child", run = run_live},
	{name = "logo", about = "assets/logo*.png and .project/image.png, drawn by the toolkit's paint package", run = run_logo},
	{name = "shots", about = "[--out folder]: the pictures of the README, the program's own frames in a sway nobody sees", run = run_shots},
	{name = "bench", about = "[seconds]: a release build in a sway nobody sees: the time to its first frame, its CPU use at rest", run = run_bench},
	{name = "package", about = "[version]: build/dist/inspecteur-<version>-linux-x64.tar.gz and its SHA-256", run = run_package},
	{name = "notes", about = "<version>: the changelog's section of that version", run = run_notes},
	{name = "ship", about = "<version> [--dry-run]: from a clean main, the changelog and APP_VERSION, the checks, a commit, the tag, the push", run = run_ship},
	{name = "site", about = "build <site> <out> | check [--site folder] [--shot file.png] [--browser program]: the site's pages", run = run_site},
}

main :: proc() {
	if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "-h" || os.args[1] == "--help" { usage(); return }
	if !os.exists(ROOT_MARK) {
		root, code := toolbox.capture({"git", "rev-parse", "--show-toplevel"})
		if code != 0 { fmt.eprintln("inspecteurtool: not in the repository"); os.exit(EXIT_USAGE) }
		if os.set_working_directory(strings.trim_space(root)) != nil { fmt.eprintfln("inspecteurtool: cannot work in %s", root); os.exit(EXIT_USAGE) }
	}
	commands := COMMANDS
	for c in commands {
		if c.name == os.args[1] { os.exit(c.run(os.args[2:])) }
	}
	fmt.eprintfln("inspecteurtool: no command %s", os.args[1])
	usage()
	os.exit(EXIT_USAGE)
}

usage :: proc() {
	fmt.println("inspecteurtool <command> [arguments]")
	commands := COMMANDS
	for c in commands { fmt.printfln("  %-6s %s", c.name, c.about) }
}
