package inspecteur

// The Connections section (connections.odin): a table of the sockets and their processes. Its bar and a row's menu
// act on the selected socket's process:
//
//   End task           Delete        SIGTERM to the process
//   Kill…              Shift+Delete  SIGKILL, after a confirmation
//   Open in Processes  Enter         the process, selected in the Processes section
//   Copy address       Ctrl+C        the remote address, else the local one

import "core:fmt"
import "core:strings"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"

build_connections :: proc(app: ^App, em: f32) {
	c := &app.connections
	if c.grid.query != app.query { grid_apply(&c.grid, &c.data, app.query) }
	listening := 0
	for s in c.sockets { if socket_listens(s) { listening += 1 } }
	note := c.read ? fmt.tprintf("%s, %d listening or open", count_text(len(c.sockets), "socket", "sockets"), listening) : "Reading…"
	section_bar(app, "Connections", note, em, connections_actions)
	ev := grid_build(app, &c.grid, &c.data, c.read ? "No socket." : "", em)
	if ev.sorted { grid_apply(&c.grid, &c.data, app.query) }
	if ev.activated { connection_reveal(app) }
	if ev.menu { connections_menu_open(app, ui.mouse_pos()) }
	connections_menu(app, em)
}

// The selected socket, when there is one.
selected_socket :: proc(app: ^App) -> (s: Socket, ok: bool) {
	i := grid_selected(&app.connections.grid)
	if i < 0 || i >= len(app.connections.sockets) { return }
	return app.connections.sockets[i], true
}

@(private = "file")
connections_actions :: proc(app: ^App, em: f32) {
	s, ok := selected_socket(app)
	owned := ok && s.pid > 0
	if tool_button(app, "end_task", lucide.X, "End task (Delete)", owned, em) { connection_signal(app, false) }
	if tool_button(app, "kill", lucide.ZAP, "Kill (Shift+Delete)", owned, em) { connection_signal(app, true) }
	vrule(em)
	if tool_button(app, "open_process", lucide.LAYOUT_LIST, "Open in Processes (Enter)", owned, em) { connection_reveal(app) }
	if tool_button(app, "copy_address", lucide.COPY, "Copy address (Ctrl+C)", ok, em) { connection_copy(app) }
}

// The keys of the section (view_keys calls it when no menu or dialog is open). `field_keeps`: the filter keeps Delete.
connections_keys :: proc(app: ^App, field_keeps: bool) {
	c := &app.connections
	grid_keys(&c.grid)
	if !field_keeps {
		if ui.key_press(.Delete) { connection_signal(app, false) }
		if ui.key_press(.Delete, {.Shift}) { connection_signal(app, true) }
		if ui.key_press(.C, {.Ctrl}) { connection_copy(app) }
	}
	if ui.key_press(.Return) { connection_reveal(app) }
	if ui.key_press(.Menu) || ui.key_press(.F10, {.Shift}) { connections_menu_open(app, {c.grid.sel_rect.min.x + 40, c.grid.sel_rect.max.y}, true) }
}

@(private = "file")
connections_menu_open :: proc(app: ^App, pos: ui.Vec2, from_keyboard := false) {
	c := &app.connections
	if _, ok := selected_socket(app); !ok { return }
	if c.menu == 0 { c.menu = ui.key_from_string(0, "inspecteur_connection_menu") }
	ui.ctx_menu_open(c.menu, pos, from_keyboard = from_keyboard)
}

@(private = "file")
connections_menu :: proc(app: ^App, em: f32) {
	c := &app.connections
	if c.menu == 0 { return }
	if ui.ctx_menu(c.menu, em * MENU_WIDTH_EM) {
		s, ok := selected_socket(app)
		if !ok { ui.ctx_menu_close(); return }
		owned := s.pid > 0
		if ui.menu_item("End task", "Delete", enabled = owned).clicked { connection_signal(app, false) }
		if ui.menu_item("Kill…", "Shift+Del", enabled = owned).clicked { connection_signal(app, true) }
		ui.menu_separator()
		if ui.menu_item("Open in Processes", "Enter", enabled = owned).clicked { connection_reveal(app) }
		if ui.menu_item("Copy address", "Ctrl+C").clicked { connection_copy(app) }
	}
}

// End task on the selected socket's process; Kill asks first, as in the Processes section.
@(private = "file")
connection_signal :: proc(app: ^App, kill: bool) {
	s, ok := selected_socket(app)
	if !ok || s.pid <= 0 { return }
	p := find_proc(&app.sampler, s.pid, s.start)
	if p == nil { say(app, "PID %d has ended already", s.pid); return }
	c: Chosen
	defer chosen_free(&c)
	append(&c.targets, Target{p.pid, p.start})
	c.name = strings.clone(fmt.tprintf("%s (PID %d)", p.name, p.pid))
	if kill { kill_ask(app, c) } else { send_signal(app, &c, .SIGTERM) }
}

@(private = "file")
connection_reveal :: proc(app: ^App) {
	s, ok := selected_socket(app)
	if !ok || s.pid <= 0 { return }
	if !processes_reveal(app, s.pid, s.start) { say(app, "PID %d has ended", s.pid) }
}

@(private = "file")
connection_copy :: proc(app: ^App) {
	s, ok := selected_socket(app)
	if !ok { return }
	text := remote_text(s)
	if text == "" { text = endpoint_text(s.local, s.lport, s.v6) }
	platform.set_clipboard(app.main.win, text)
	say(app, "Copied %s", text)
}
