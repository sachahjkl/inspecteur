package inspecteurtool

// build, test, check: the program and its tests, on the toolkit's toolbox.Project.

import "core:fmt"
import "core:os"
import changelog "gt:changelog"
import toolbox "gt:toolbox"

PROGRAM    :: "build/inspecteur"
REPOSITORY :: "https://github.com/sachahjkl/inspecteur"
CHANGELOG  :: "CHANGELOG.md"

// What inspecteur's project is to this tool and to the toolkit's commands.
project :: proc() -> toolbox.Project {
	return {
		name = "inspecteur", repository = REPOSITORY, changelog = CHANGELOG,
		version_file = "src/main.odin", version_line = "APP_VERSION :: ", program = PROGRAM,
	}
}

run_build :: proc(args: []string) -> int {
	release := len(args) > 0 && args[0] == "release"
	p := project()
	if !toolbox.build_native(p) { return 1 }
	_ = os.make_directory("build")
	extra := []string{"-out:" + PROGRAM, release ? "-o:speed" : "-debug"}
	if !toolbox.run(toolbox.odin_command(p, "build", "", extra), {echo = true}) { return 1 }
	fmt.printfln("built %s%s", PROGRAM, release ? " (release)" : "")
	return 0
}

run_test :: proc(args: []string) -> int {
	p := project()
	if !toolbox.build_native(p) { return 1 }
	_ = os.make_directory("build")
	return toolbox.run(toolbox.odin_command(p, "test", "", {"-out:build/test_inspecteur"}), {echo = true}) ? 0 : 1
}

run_check :: proc(args: []string) -> int {
	p := project()
	// (no check for Windows, toolbox.check_windows: every reader of the system is a *_linux.odin file, and Windows has
	// none yet: docs/architecture.md, "Porting to Windows")
	if !toolbox.run(toolbox.odin_command(p, "check"), {echo = true}) { return 1 }
	if !toolbox.run(toolbox.odin_command(p, "check", "tools/inspecteurtool"), {echo = true}) { return 1 }
	if !toolbox.check_scopes("src") { return 1 }
	if run_test(nil) != 0 { return 1 }
	pp := p
	problems, fragments := changelog.check(changelog.project_options(&pp))
	for e in problems { fmt.eprintfln("inspecteurtool check: %s", e) }
	if len(problems) > 0 { return 1 }
	fmt.printfln("changelog: %d fragments, well formed", fragments)
	if why := toolbox.third_party_notices(p, toolbox.NOTICES_FILE, check_only = true); why != "" {
		fmt.eprintfln("inspecteurtool check: %s", why)
		return 1
	}
	return run_build({"release"})
}
