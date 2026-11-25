package inspecteurtool

// build, test, check: the toolkit's (toolbox.build_commands), on inspecteur's toolbox.Project.

import "core:fmt"
import "core:os"
import "core:strings"
import changelog "gt:changelog"
import toolbox "gt:toolbox"

when ODIN_OS == .Windows {
	PROGRAM :: "build/inspecteur.exe"
} else {
	PROGRAM :: "build/inspecteur"
}
REPOSITORY :: "https://github.com/sachahjkl/inspecteur"
CHANGELOG  :: "CHANGELOG.md"

// (one thread: the tests that build a window's interface each take the toolkit's one test session)
@(rodata)
TESTS := [?]toolbox.Test_Package{
	{path = "src", one_thread = true},
	{path = "src/winapi"},
}

@(rodata)
CHECKS := [?]toolbox.Build_Check{check_no_odin_os, check_winapi_targets}

// The texts' catalogues: i18n/<language>.txt, against the texts of src (a variable: a constant's slice is made again
// on the stack where it is used).
I18N := toolbox.I18n_Catalogues{dirs = {"src"}, folder = "i18n"}

// What inspecteur's project is to this tool and to the toolkit's commands, and what Windows shows of it.
project :: proc() -> toolbox.Project {
	return {
		name = "inspecteur", repository = REPOSITORY, changelog = CHANGELOG,
		version_file = "src/main.odin", version_line = "APP_VERSION :: ", program = PROGRAM,
		// (live, shots and bench drive the release build over CDP: Devtools; only the icons inspecteur names: Lucide_Subset)
		features = {.Devtools, .Lucide_Subset},
		launcher = {default_rule = "detach", others = "--install,--uninstall,--status,prefs,version,--version,help,-h,--help", refuses_exit = 2},
		title = "Inspecteur", description = "What runs on this computer: its processes, performance, services, startup and connections.",
		publisher = "Froment Software", copyright = "Copyright (c) 2026 sachahjkl",
	}
}

// (notices: the archive ships THIRD-PARTY-NOTICES, so check keeps it up to date)
build_options :: proc() -> toolbox.Build_Options {
	p := project()
	return {project = p, changelog_command = changelog.command(p), tests = TESTS[:], catalogues = I18N, checks = CHECKS[:], notices = true}
}

// Enforces porting.md's architectural rule: platform differences live in whole per-OS files selected by build suffixes,
// never in `when ODIN_OS` branches sprinkled inside src/.
check_no_odin_os :: proc(_: toolbox.Project) -> bool {
	entries, err := os.read_all_directory_by_path("src", context.temp_allocator)
	if err != nil { fmt.eprintln("check: cannot read src/"); return false }
	ok := true
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".odin") { continue }
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil { continue }
		text := string(data)
		line_no := 0
		for line in strings.split_lines_iterator(&text) {
			line_no += 1
			if strings.contains(line, "ODIN_OS") {
				fmt.eprintfln("%s:%d: use a per-OS file suffix instead of ODIN_OS", e.fullpath, line_no)
				ok = false
			}
		}
	}
	return ok
}

// Verifies src/winapi pure ABI layout #asserts across amd64 and arm64 targets (no wgpu dependency).
check_winapi_targets :: proc(_: toolbox.Project) -> bool {
	targets := [?]string{"windows_amd64", "linux_amd64", "linux_arm64", "darwin_arm64"}
	for t in targets {
		if !toolbox.run({"odin", "check", "src/winapi", "-vet", "-no-entry-point", fmt.tprintf("-target:%s", t)}, {echo = true}) {
			return false
		}
	}
	return true
}
