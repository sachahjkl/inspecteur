package inspecteur

import "base:runtime"
import "core:testing"
import instance "gt:instance"
import "gt:platform"

// --quit ends the running Inspecteur as closing its window does: its loop (app_run) ends at is_closed, then keeps the
// preferences and the views. A ping (--status) changes nothing: a running copy must not close because it was asked
// whether it runs. An offscreen window: nothing appears on the desktop.
@(test)
one_copy_quit_closes_and_ping_does_not :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	win := platform.open_window_offscreen("inspecteur test", {64, 64})
	if !testing.expect(t, win != nil, "an offscreen window") { return }
	defer platform.destroy_window(win)
	app := new(App)
	defer free(app)
	app.main.win = win

	one_copy_receive(app, instance.MESSAGE_PING)
	platform.poll_events(win, false)
	testing.expect(t, !platform.is_closed(win), "a ping leaves the window open")

	one_copy_receive(app, instance.MESSAGE_QUIT)
	platform.poll_events(win, false)
	testing.expect(t, platform.is_closed(win), "a quit closes the window, as its Quit does")
}
