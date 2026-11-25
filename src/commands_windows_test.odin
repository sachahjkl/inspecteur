#+build windows
package inspecteur

// Windows-specific command palette tests (Startup type choices and Efficiency mode command).

import "core:slice"
import "core:strings"
import "core:testing"

@(test)
win_command_choices_offer_priorities_and_startup_types :: proc(t: ^testing.T) {
	app := demo_rows()
	defer demo_rows_free(app)

	_, pvals := command_choices(app, 0, "priority")
	testing.expect(t, slice.contains(pvals, "0"), "Normal priority is offered")

	labels, svals := command_choices(app, 0, "startup_type")
	testing.expect_value(t, len(labels), len(WIN_EDITABLE_STARTUPS))
	testing.expect_value(t, len(svals), len(WIN_EDITABLE_STARTUPS))
	testing.expect(t, slice.contains(svals, STARTUP_TYPE_ARGUMENTS[0].default.s), "the default is offered")
}

@(test)
win_efficiency_mode_refuses_demo_cleanly :: proc(t: ^testing.T) {
	app := demo_rows()
	defer demo_rows_free(app)
	testing.expect(t, cmd_can(app, .Efficiency_Mode), "a process is selected")
	cmd_run(app, .Efficiency_Mode)
	testing.expectf(t, strings.contains(app.status, "Efficiency mode"), "footer: %q", app.status)
}
