package inspecteur

// The Connections section's model: the TCP and UDP sockets of the machine, IPv4 and IPv6, each with the process that
// holds it when the user may know it. The reading is the system's (connections_linux.odin: sockets_read); it runs on a
// thread of its own (the toolkit's ui.Worker), and only while the section is shown: telling each socket's process costs some
// milliseconds.

import "core:net"
import "core:strconv"
import "core:strings"
import lucide "gt:lucide"
import "gt:ui"

Proto :: enum u8 { TCP, UDP }

Socket_State :: enum u8 {
	Unknown, Established, Syn_Sent, Syn_Received, Fin_Wait_1, Fin_Wait_2, Time_Wait, Closed, Close_Wait, Last_Ack,
	Listening, Closing,
	Open,        // UDP, not connected: it takes datagrams from anyone
	Connected,   // UDP, connected to one remote end
}

SOCKET_STATE_TEXT := [Socket_State]string{
	.Unknown = "?", .Established = "Established", .Syn_Sent = "SYN sent", .Syn_Received = "SYN received",
	.Fin_Wait_1 = "FIN wait 1", .Fin_Wait_2 = "FIN wait 2", .Time_Wait = "Time wait", .Closed = "Closed",
	.Close_Wait = "Close wait", .Last_Ack = "Last ACK", .Listening = "Listening", .Closing = "Closing", .Open = "Open",
	.Connected = "Connected",
}

Socket :: struct {
	proto:  Proto,
	v6:     bool,
	local:  [16]u8,   // IPv4: the first 4 bytes
	remote: [16]u8,
	lport, rport: u16,
	state:  Socket_State,
	key:    u64,      // the system's identity of the socket (an inode on Linux); 0: none
	pid:    i32,      // the process that holds it; 0: not known (another user's, or a socket in TIME_WAIT)
	start:  u64,      // and its start time (its identity, for End task)
}

Connections :: struct {
	worker:  ui.Worker,
	reader:  Socket_Reader,     // the thread's own (connections_linux.odin)
	demo:    ^Demo,             // not nil: the sockets are the demo's
	shared:  [dynamic]Socket,   // the thread's last reading, under the worker's mutex
	sockets: [dynamic]Socket,   // the window's copy
	rows:    Section_Table,
	read:    bool,              // a reading came at least once
	menu:    ui.Key,
}

CONN_COLUMNS := [?]ui.Table_Column{
	{title = "Process", width = 0},
	{title = "PID", width = 5.5, number = true, weak = true},
	{title = "Protocol", width = 6},
	{title = "Local address", width = 17},
	{title = "Remote address", width = 17},
	{title = "State", width = 8.5, weak = true},
}

connections_init :: proc(c: ^Connections, app: ^App) {
	section_table_init(&c.rows, app, CONN_COLUMNS[:])
	c.demo = app.demo
	ui.worker_start(&c.worker, connections_job, c, app.main.win)
}

connections_destroy :: proc(c: ^Connections) {
	ui.worker_stop(&c.worker)
	socket_reader_destroy(&c.reader)
	delete(c.shared)
	delete(c.sockets)
	section_table_destroy(&c.rows)
}

@(private = "file")
connections_job :: proc(w: ^ui.Worker) {
	c := (^Connections)(w.user)
	list := make([dynamic]Socket, context.temp_allocator)
	if c.demo != nil { demo_sockets_read(c.demo, &list) } else { sockets_read(&c.reader, &list) }
	ui.worker_lock(w)
	clear(&c.shared)
	append(&c.shared, ..list[:])
	ui.worker_unlock(w)
	ui.worker_published(w)
}

// The window's turn: a new reading becomes the rows.
connections_take :: proc(app: ^App) {
	c := &app.connections
	if !ui.worker_take(&c.worker) { return }
	ui.worker_lock(&c.worker)
	clear(&c.sockets)
	append(&c.sockets, ..c.shared[:])
	ui.worker_unlock(&c.worker)
	c.read = true
	connections_rows(app)
}

// The rows again from the sockets.
connections_rows :: proc(app: ^App) {
	c := &app.connections
	st := &c.rows
	section_rows_reset(st, len(CONN_COLUMNS))
	buf: [16]u8
	for s in c.sockets {
		name := "—"
		pid := ""
		icon := Row_Icon{glyph = lucide.SQUARE_TERMINAL}
		if s.pid > 0 {
			pid = strings.clone(strconv.write_int(buf[:], i64(s.pid), 10), context.temp_allocator)
			name = pid
			if p := find_proc(&app.sampler, s.pid, s.start); p != nil {
				name = p.name
				if p.entry >= 0 { icon.app = app.catalog.entries[p.entry].icon }
			}
		}
		proto := s.v6 ? (s.proto == .TCP ? "TCPv6" : "UDPv6") : (s.proto == .TCP ? "TCP" : "UDP")
		local := endpoint_text(s.local, s.lport, s.v6)
		remote := remote_text(s)
		state := SOCKET_STATE_TEXT[s.state]
		section_row(st, socket_id(s), strings.join({name, pid, proto, local, remote, state}, " ", context.temp_allocator), icon, s.pid > 0 ? .Normal : .Dim)
		ui.table_data_cell(&st.data, name)
		ui.table_data_cell(&st.data, pid, f64(s.pid))
		ui.table_data_cell(&st.data, proto)
		ui.table_data_cell(&st.data, local)
		ui.table_data_cell(&st.data, remote)
		ui.table_data_cell(&st.data, state)
	}
	ui.table_apply(&st.table, &st.data, app.query)
}

// Whether the socket waits for others: a TCP socket that listens, a UDP socket open to anyone.
socket_listens :: proc(s: Socket) -> bool { return s.state == .Listening || s.state == .Open }

// A socket's identity across readings: the system's, else (a TCP socket in TIME_WAIT has none) its addresses.
socket_id :: proc(s: Socket) -> u64 {
	if s.key != 0 { return s.key | 1 << 63 }
	h: u64 = 14695981039346656037   // FNV-1a
	mix :: proc(h: ^u64, b: u8) { h^ = (h^ ~ u64(b)) * 1099511628211 }
	for b in s.local { mix(&h, b) }
	for b in s.remote { mix(&h, b) }
	mix(&h, u8(s.lport)); mix(&h, u8(s.lport >> 8)); mix(&h, u8(s.rport)); mix(&h, u8(s.rport >> 8))
	mix(&h, u8(s.proto)); mix(&h, u8(s.v6))
	return h & ~(u64(1) << 63)
}

// "127.0.0.1:631", "[::1]:631", "*:68" (any address).
endpoint_text :: proc(addr: [16]u8, port: u16, v6: bool) -> string {
	a := addr
	zero := true
	for b in a[:v6 ? 16 : 4] { if b != 0 { zero = false } }
	host: string
	if zero {
		host = "*"
	} else if v6 {
		ip: net.IP6_Address
		for i in 0 ..< 8 { ip[i] = u16be(u16(a[2 * i]) << 8 | u16(a[2 * i + 1])) }
		host = strings.concatenate({"[", net.address_to_string(ip, context.temp_allocator), "]"}, context.temp_allocator)
	} else {
		host = net.address_to_string(net.IP4_Address{a[0], a[1], a[2], a[3]}, context.temp_allocator)
	}
	buf: [8]u8
	return strings.concatenate({host, ":", port == 0 ? "*" : strconv.write_uint(buf[:], u64(port), 10)}, context.temp_allocator)
}

// The remote end: none for a socket that listens or takes datagrams from anyone.
remote_text :: proc(s: Socket) -> string {
	zero := s.rport == 0
	for b in s.remote { if b != 0 { zero = false } }
	if zero { return "" }
	return endpoint_text(s.remote, s.rport, s.v6)
}
