// inspecteurtool: the project's machinery, one program, whatever the shell.
//
//   odin run tools/inspecteurtool -collection:gt=ext/gui_toolkit/src -out:build/inspecteurtool -- <command>
//   (build.sh and build.bat are its shortcuts for `build`)
//
// What it needs is on the path: git, odin, cargo (the toolkit's text library); sway for live, shots and bench.
// GT=<folder>: another checkout of gui_toolkit (its root, not its src). The dispatcher, the changelog's, the site's,
// the release's, the logo's and the notices' commands are the toolkit's (gt:toolbox, docs/toolbox.md).
package inspecteurtool

import changelog "gt:changelog"
import release "gt:release"
import toolbox "gt:toolbox"
import inspecteur_licence "../../src/licence"
import inspecteur_update "../../src/update"

EXIT_USAGE :: toolbox.EXIT_USAGE

// The development pair's private key, public on purpose ("inspecteur-dev-licence-seed-01!!"): the tests, the pictures
// and the shop's sandbox register with it; only a debug build of inspecteur accepts it (src/licence/product.odin).
DEV_SEED :: "aW5zcGVjdGV1ci1kZXYtbGljZW5jZS1zZWVkLTAxISE"

// The `licence` and `paddle` commands: inspecteur's licence (src/licence.odin), its development pair, its Paddle
// catalogue.
LICENCE_TOOL :: toolbox.Licence_Tool{
	product  = inspecteur_licence.PRODUCT,
	dev_seed = DEV_SEED,
	hint     = "Open inspecteur's settings (Ctrl+,), the General page: choose this file, or paste the key there.",
	paddle   = {name = "Inspecteur User License", description = "A personal, perpetual licence of inspecteur, the task manager.", amounts = "supporter=1500", currency = "EUR"},
}

main :: proc() {
	p := project()
	r := release.commands(release_config(p))
	l := toolbox.licence_commands(LICENCE_TOOL)
	toolbox.tool_main("inspecteurtool", {
		{name = "build", usage = "[release]: the toolkit's text library when its sources changed, then build/inspecteur", run = run_build},
		{name = "test", usage = ": the unit tests of the program", run = run_test},
		{name = "check", usage = ": odin check of the program and of this tool (-vet), its scopes, the tests, the changelog's fragments, the French catalogue, THIRD-PARTY-NOTICES up to date, then a release build", run = run_check},
		{name = "live", usage = "[--keep]: the real program in a sway nobody sees, driven as a person would; it acts only on what it made", run = run_live},
		toolbox.logo_command(logo()),
		{name = "shots", usage = "[--out folder]: the pictures of the documentation, of the demo's made-up machine, in a sway nobody sees", run = run_shots},
		{name = "bench", usage = "[seconds]: a release build in a sway nobody sees: the time to its first frame, its CPU use at rest", run = run_bench},
		{name = "desktop_files", usage = "<prefix>: the desktop entry and the icons under <prefix>/share (the Nix package's)", run = run_desktop_files},
		toolbox.notices_command(p),
		r[0], r[1], r[2],
		{name = "update", usage = "keygen <file> | pubkey | manifest <program> <version> - <out> | verify <manifest> -: inspecteur's update key and manifests", run = proc(args: []string) -> int { return toolbox.update_command(inspecteur_update.PRODUCT, args) }},
		changelog.command(p),
		toolbox.i18n_command({dirs = {"src"}, folder = "i18n"}),
		site_command(),
		l[0], l[1],
	}, toolbox.ROOT_MARK_DEFAULT)
}
