package inspecteurtool

// A release, the same steps on a laptop and in the release workflow, with the toolkit's (gt:release, gt:changelog):
//
//   package [version]       build/dist: inspecteur-<version>-linux-x64.tar.gz (the program, its licence and the
//                           third-party notices, the README and the changelog), its SHA-256, the program alone and, with
//                           $UPDATE_SIGNING_KEY, its signed update manifest; a version given must be APP_VERSION
//   notes <version>         the changelog's section of that version (the notes of its GitHub release)
//   ship <version> [--dry-run]
//                           from a clean main: the fragments of changelog.d/ assembled into [<version>] with today's date,
//                           APP_VERSION set, the checks, a commit, the tag v<version>, the push. The release workflow
//                           builds the archive and publishes it; the site follows.
//   changelog new <type> <subject> <text> | check | preview
//                           a change a user can see is a fragment of changelog.d/ (docs/development.md), never an edit
//                           of CHANGELOG.md

import "core:fmt"
import "core:os"
import "core:strings"
import changelog "gt:changelog"
import release "gt:release"
import toolbox "gt:toolbox"
import inspecteur_update "../../src/update"

CHANGELOG    :: "CHANGELOG.md"
VERSION_FILE :: "src/main.odin"
VERSION_LINE :: "APP_VERSION :: "
REPOSITORY   :: "https://github.com/sachahjkl/inspecteur"
// The branch a version is made from.
RELEASE_BRANCH :: "main"

// What goes beside the program in the archive: the file, and its name there (THIRD-PARTY-NOTICES holds the licences of
// what the program embeds and links: inspecteurtool notices).
@(rodata)
DIST_FILES := [?][2]string{{"README.md", "README.md"}, {"LICENSE", "LICENSE"}, {"THIRD-PARTY-NOTICES", "THIRD-PARTY-NOTICES"}, {"CHANGELOG.md", "CHANGELOG.md"}}

release_config :: proc() -> release.Config {
	return {
		name = "inspecteur", repository = REPOSITORY, changelog = CHANGELOG, version_file = VERSION_FILE, version_line = VERSION_LINE,
		program = PROGRAM, dist = "build/dist", files = DIST_FILES[:], check = proc() -> int { return run_check(nil) },
		update = inspecteur_update.PRODUCT,
	}
}

changelog_options :: proc() -> changelog.Options {
	return {root = ".", link = REPOSITORY + "/releases/tag/v%s"}
}

run_package :: proc(args: []string) -> int { return release.package_(release_config(), args) }

run_notes :: proc(args: []string) -> int { return release.notes(release_config(), args) }

// (gt:release's ship makes a version from master: Inspecteur's branch is main)
run_ship :: proc(args: []string) -> int {
	if len(args) == 0 { fmt.eprintln("inspecteurtool ship <version> [--dry-run]"); return EXIT_USAGE }
	version := strings.trim_prefix(args[0], "v")
	dry := len(args) > 1 && args[1] == "--dry-run"
	if _, ok := release.semver(version); !ok { fmt.eprintfln("inspecteurtool: %s is not x.y.z", version); return EXIT_USAGE }
	data, rerr := os.read_entire_file(VERSION_FILE, context.temp_allocator)
	if rerr != nil { fmt.eprintfln("inspecteurtool: %s cannot be read", VERSION_FILE); return 1 }
	source := string(data)
	current := release.version_of(source, VERSION_LINE)
	if !release.semver_newer(current, version) && current != version { fmt.eprintfln("inspecteurtool: %s does not come after %s", version, current); return 1 }
	branch, _ := toolbox.capture({"git", "rev-parse", "--abbrev-ref", "HEAD"})
	if strings.trim_space(branch) != RELEASE_BRANCH { fmt.eprintfln("inspecteurtool: ship from %s", RELEASE_BRANCH); return 1 }
	if status, _ := toolbox.capture({"git", "status", "--porcelain"}); strings.trim_space(status) != "" {
		fmt.eprintln("inspecteurtool: the working tree is not clean")
		return 1
	}
	o := changelog_options()
	problems, fragments := changelog.check(o)
	for p in problems { fmt.eprintfln("inspecteurtool: %s", p) }
	if len(problems) > 0 { return 1 }
	section, _ := changelog.preview(o.root)
	if section == "" { fmt.eprintln("inspecteurtool: nothing to release: no fragment in changelog.d/"); return 1 }
	new_source, sok := release.version_set(source, VERSION_LINE, version)
	if !sok { fmt.eprintfln("inspecteurtool: %s has no %s line", VERSION_FILE, VERSION_LINE); return 1 }
	if dry {
		fmt.printfln("ship %s (dry run): the section it releases\n%s", version, section)
		return 0
	}
	_, errors := changelog.assemble(o, version)
	for e in errors { fmt.eprintfln("inspecteurtool: %s", e) }
	if len(errors) > 0 { return 1 }
	if os.write_entire_file(VERSION_FILE, new_source) != nil { return 1 }
	if run_check(nil) != 0 { fmt.eprintln("inspecteurtool: the checks failed: nothing is committed (git checkout . takes the changes back)"); return 1 }
	add := make([dynamic]string, context.temp_allocator)
	append(&add, "git", "add", "-A", "--", CHANGELOG, VERSION_FILE)
	if fragments > 0 { append(&add, "changelog.d") }
	steps := [][]string{
		add[:],
		{"git", "commit", "-m", fmt.tprintf("inspecteur %s", version)},
		{"git", "tag", "-a", fmt.tprintf("v%s", version), "-m", fmt.tprintf("inspecteur %s", version)},
		{"git", "push", "origin", RELEASE_BRANCH, fmt.tprintf("v%s", version)},
	}
	for s in steps { if !toolbox.run(s, {echo = true}) { return 1 } }
	fmt.printfln("shipped v%s: the release workflow builds and publishes it (%s/actions)", version, REPOSITORY)
	return 0
}

// `changelog new <type> <subject> <text>`: a fragment; `check`: every fragment well formed (check runs it); `preview`:
// what the next version brings.
run_changelog :: proc(args: []string) -> int {
	usage :: "inspecteurtool changelog new <Added|Changed|Deprecated|Removed|Fixed|Security> <subject> <text> | check | preview"
	if len(args) == 0 { fmt.eprintln(usage); return EXIT_USAGE }
	switch args[0] {
	case "new":
		if len(args) != 4 { fmt.eprintln(usage); return EXIT_USAGE }
		path, why := changelog.new_fragment(".", args[1], args[2], args[3])
		if why != "" { fmt.eprintfln("inspecteurtool: %s", why); return 1 }
		fmt.printfln("wrote %s", path)
	case "check":
		errors, fragments := changelog.check(changelog_options())
		for e in errors { fmt.eprintfln("inspecteurtool: %s", e) }
		if len(errors) > 0 { return 1 }
		fmt.printfln("changelog: %d fragments, well formed", fragments)
	case "preview":
		text, errors := changelog.preview(".")
		for e in errors { fmt.eprintfln("inspecteurtool: %s", e) }
		if len(errors) > 0 { return 1 }
		fmt.print(text == "" ? "nothing to release\n" : text)
	case:
		fmt.eprintln(usage)
		return EXIT_USAGE
	}
	return 0
}
