package inspecteurtool

// build, test, check: the toolkit's (toolbox.build_commands), on inspecteur's toolbox.Project.

import changelog "gt:changelog"
import toolbox "gt:toolbox"

PROGRAM    :: "build/inspecteur"
REPOSITORY :: "https://github.com/sachahjkl/inspecteur"
CHANGELOG  :: "CHANGELOG.md"

// (one thread: the tests that build a window's interface each take the toolkit's one test session)
@(rodata)
TESTS := [?]toolbox.Test_Package{{path = "src", one_thread = true}}

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
		title = "Inspecteur", description = "What runs on this computer: its processes, performance, services, startup and connections.",
		publisher = "Froment Software", copyright = "Copyright (c) 2026 sachahjkl",
	}
}

// (notices: the archive ships THIRD-PARTY-NOTICES, so check keeps it up to date)
build_options :: proc() -> toolbox.Build_Options {
	p := project()
	return {project = p, changelog_command = changelog.command(p), tests = TESTS[:], catalogues = I18N, notices = true}
}
