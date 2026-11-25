#+build !windows
package inspecteur

import "core:slice"
import "core:strings"
import "core:testing"

// A systemd Go to service item's id names its manager and name, and reads back.
@(test)
go_to_service_ids_read_back :: proc(t: ^testing.T) {
	m, name, sok := go_to_service_parse(go_to_service_id(.User, "foo.service"))
	testing.expect(t, sok && m == .User && name == "foo.service")
	_, _, other := go_to_service_parse("nobody/foo.service")
	testing.expect(t, !other)
}

// Send a signal with its form's value: that signal goes to the row selected, and to it alone.
@(test)
send_a_signal_takes_its_form_s_signal :: proc(t: ^testing.T) {
	app := demo_rows()
	defer demo_rows_free(app)
	_, values := command_choices(app, 0, "signal")
	testing.expect(t, slice.contains(values, "SIGUSR1"), "SIGUSR1 is offered")
	testing.expect(t, cmd_can(app, .Send_Signal), "a process is selected")
	cmd_run_with(app, .Send_Signal, {"SIGUSR1"})
	testing.expectf(t, strings.contains(app.status, "SIGUSR1") && strings.contains(app.status, "a (PID 20)") && !strings.contains(app.status, "PID 21"), "the footer: %q", app.status)
}
