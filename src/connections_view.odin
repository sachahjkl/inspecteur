package inspecteur

// The Connections section (connections.odin): a table of the sockets and their processes. Its bar, a row's menu and the
// keys (commands.odin) act on the processes of the sockets selected: End task, Kill (after a confirmation), Copy address
// (the remote address, else the local one); and on the cursor's: Open in Processes (the process, selected there).

import "core:fmt"
import "core:strings"
import lucide "gt:lucide"
import "gt:platform"
import "gt:ui"
import i18n "gt:i18n"

build_connections :: proc(app: ^App, em: f32) {
	c := &app.connections
	if c.rows.table.query != app.query { ui.table_apply(&c.rows.table, &c.rows.data, app.query) }
	listening := 0
	for s in c.sockets { if socket_listens(s) { listening += 1 } }
	note := c.read ? fmt.tprintf(i18n.tr(len(c.sockets), "%d socket, %d listening or open", "%d sockets, %d listening or open"), len(c.sockets), listening) : i18n.tr("Reading…")
	section_bar(app, i18n.tr("Connections"), note, em, connections_actions)
	ev := section_table_build(&c.rows, c.read ? i18n.tr("No socket.") : "")
	if ev.sorted { ui.table_apply(&c.rows.table, &c.rows.data, app.query) }
	if ev.sorted || ev.resized || ev.moved { section_layout_save(&c.rows, &app.prefs, "connections") }
	section_header_menu(&c.rows, ev, "connections", em)
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

CONNECTIONS_MENU :: "inspecteur_connection_menu"

connections_menu_open :: proc(app: ^App, pos: ui.Vec2, from_keyboard := false) {
	if _, ok := selected_socket(app); !ok { return }
	ui.menu_open(CONNECTIONS_MENU, pos, from_keyboard = from_keyboard)
}

@(private = "file")
connections_menu :: proc(app: ^App, em: f32) {
	if ui.menu(CONNECTIONS_MENU) {
		s, ok := selected_socket(app)
		if !ok { ui.menu_close(); return }
		_ = s
		cmd_item(app, .Socket_End_Task)
		cmd_item(app, .Socket_Kill)
		ui.menu_separator()
		cmd_item(app, .Socket_Open)
		cmd_item(app, .Socket_Copy)
	}
}

// The processes of the sockets selected, each once (a process holds many sockets), those still running; `gone`: the pid
// of a socket's process that has ended (0: none).
sockets_chosen :: proc(app: ^App) -> (c: Chosen, gone: i32) {
	seen := make(map[i32]bool, 16, context.temp_allocator)
	for r in selected_rows(&app.connections.rows.table) {
		if r >= len(app.connections.sockets) { continue }
		s := app.connections.sockets[r]
		if s.pid <= 0 || s.pid in seen { continue }
		seen[s.pid] = true
		p := find_proc(&app.sampler, s.pid, s.start)
		if p == nil { gone = s.pid; continue }
		append(&c.targets, Target{p.pid, p.start})
		if len(c.targets) == 1 { c.name = strings.clone(fmt.tprintf(i18n.tr("%s (PID %d)"), p.name, p.pid)) }
	}
	if len(c.targets) > 1 {
		delete(c.name)
		c.name = strings.clone(fmt.tprintf(i18n.tr(len(c.targets), "%d processes", "%d processes"), len(c.targets)))
	}
	return
}

// End task on the processes of the sockets selected; Kill asks first, as in the Processes section, and so does End
// task on several: once, naming their count.
connection_signal :: proc(app: ^App, kill: bool) {
	c, gone := sockets_chosen(app)
	defer chosen_free(&c)
	if len(c.targets) == 0 {
		if gone > 0 { say(app, i18n.tr("PID %d has ended already"), gone) }
		return
	}
	switch {
	case kill:                 confirm_ask(app, c, .Kill)
	case len(c.targets) > 1:   confirm_ask(app, c, .Terminate)
	case:                      signal_or_confirm(app, &c, .Terminate)
	}
}

connection_reveal :: proc(app: ^App) {
	s, ok := selected_socket(app)
	if !ok || s.pid <= 0 { return }
	if !processes_reveal(app, s.pid, s.start) { say(app, i18n.tr("PID %d has ended"), s.pid) }
}

// The addresses of the sockets selected (the remote one, else the local one), a line each.
connection_copy :: proc(app: ^App) {
	lines := make([dynamic]string, context.temp_allocator)
	for r in selected_rows(&app.connections.rows.table) {
		if r >= len(app.connections.sockets) { continue }
		s := app.connections.sockets[r]
		text := remote_text(s)
		if text == "" { text = endpoint_text(s.local, s.lport, s.v6) }
		append(&lines, text)
	}
	if len(lines) == 0 { return }
	text := strings.join(lines[:], "\n", context.temp_allocator)
	platform.set_clipboard(app.main.win, text)
	announce(app, i18n.tr("Copied"), len(lines) == 1 ? text : fmt.tprintf(i18n.tr(len(lines), "%d address", "%d addresses"), len(lines)))
}
