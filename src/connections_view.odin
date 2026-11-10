package inspecteur

// The Connections section (connections.odin): a table of the sockets and their processes. Its bar, a row's menu and the
// keys (commands.odin) act on the selected socket's process: End task, Kill (after a confirmation), Open in Processes
// (the process, selected there), Copy address (the remote address, else the local one).

import "core:fmt"
import "core:strings"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"

build_connections :: proc(app: ^App, em: f32) {
	c := &app.connections
	if c.rows.table.query != app.query { ui.table_apply(&c.rows.table, &c.rows.data, app.query) }
	listening := 0
	for s in c.sockets { if socket_listens(s) { listening += 1 } }
	note := c.read ? fmt.tprintf("%s, %d listening or open", count_text(len(c.sockets), "socket", "sockets"), listening) : "Reading…"
	section_bar(app, "Connections", note, em, connections_actions)
	ev := section_table_build(&c.rows, c.read ? "No socket." : "")
	if ev.sorted { ui.table_apply(&c.rows.table, &c.rows.data, app.query) }
	if ev.activated && cmd_can(app, .Socket_Open) { connection_reveal(app) }
	if ev.menu { connections_menu_open(app, ev.menu_at) }
	connections_menu(app, em)
}

// The selected socket, when there is one.
selected_socket :: proc(app: ^App) -> (s: Socket, ok: bool) {
	i := ui.table_selected(&app.connections.rows.table)
	if i < 0 || i >= len(app.connections.sockets) { return }
	return app.connections.sockets[i], true
}

@(private = "file")
connections_actions :: proc(app: ^App, em: f32) {
	cmd_button(app, "end_task", lucide.X, .Socket_End_Task, em)
	cmd_button(app, "kill", lucide.ZAP, .Socket_Kill, em)
	vrule(em)
	cmd_button(app, "open_process", lucide.LAYOUT_LIST, .Socket_Open, em)
	cmd_button(app, "copy_address", lucide.COPY, .Socket_Copy, em)
}

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
	if ui.ctx_menu(c.menu) {
		s, ok := selected_socket(app)
		if !ok { ui.ctx_menu_close(); return }
		_ = s
		cmd_item(app, .Socket_End_Task)
		cmd_item(app, .Socket_Kill)
		ui.menu_separator()
		cmd_item(app, .Socket_Open)
		cmd_item(app, .Socket_Copy)
	}
}

// End task on the selected socket's process; Kill asks first, as in the Processes section.
connection_signal :: proc(app: ^App, kill: bool) {
	s, ok := selected_socket(app)
	if !ok || s.pid <= 0 { return }
	p := find_proc(&app.sampler, s.pid, s.start)
	if p == nil { say(app, "PID %d has ended already", s.pid); return }
	c: Chosen
	defer chosen_free(&c)
	append(&c.targets, Target{p.pid, p.start})
	c.name = strings.clone(fmt.tprintf("%s (PID %d)", p.name, p.pid))
	if kill { confirm_ask(app, c, .Kill) } else { signal_or_confirm(app, &c, .Terminate) }
}

connection_reveal :: proc(app: ^App) {
	s, ok := selected_socket(app)
	if !ok || s.pid <= 0 { return }
	if !processes_reveal(app, s.pid, s.start) { say(app, "PID %d has ended", s.pid) }
}

connection_copy :: proc(app: ^App) {
	s, ok := selected_socket(app)
	if !ok { return }
	text := remote_text(s)
	if text == "" { text = endpoint_text(s.local, s.lport, s.v6) }
	platform.set_clipboard(app.main.win, text)
	say(app, "Copied %s", text)
}
