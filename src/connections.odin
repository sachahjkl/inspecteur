package inspecteur

// The Connections section's model: the TCP and UDP sockets of the machine, IPv4 and IPv6, each with the process that
// holds it when the user may know it. The reading is the system's (connections_linux.odin: sockets_read); it runs in a
// tasks.Job on the toolkit's chores, whose reading comes back to the window by ui.post, and only while the section is
// shown: telling each socket's process costs some milliseconds.

import "core:net"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import lucide "gt:lucide"
import tasks "gt:tasks"
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
	job:     tasks.Job,
	reader:  Socket_Reader,     // the job's own (connections_linux.odin)
	demo:    ^Demo,             // not nil: the sockets are the demo's
	state:   ^ui.State,         // the window a reading is posted to
	sockets: [dynamic]Socket,   // the window's
	// what Mission Control says of them, counted when a reading comes (connections_posted)
	listening, connected: int,
	holders: [dynamic]Socket_Holder,   // the processes that hold sockets, the most first
	rows:    Section_Table,
	read:    bool,              // a reading came at least once
	menu:    ui.Key,
	next:    time.Tick,         // the next reading while they are shown (connections.refresh_ms)
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
	section_layout_load(&c.rows.table, &app.prefs, "connections")
	c.demo = app.demo
	c.state = &app.main.state
	c.job = {work = connections_work, data = c}
}

// After the chores stopped (no reading runs).
connections_destroy :: proc(c: ^Connections) {
	socket_reader_destroy(&c.reader)
	delete(c.sockets)
	delete(c.holders)
	section_table_destroy(&c.rows)
}

@(private = "file")
connections_work :: proc(data: rawptr) {
	c := (^Connections)(data)
	list := new([dynamic]Socket)
	if c.demo != nil { demo_sockets_read(c.demo, list) } else { sockets_read(&c.reader, list) }
	if !ui.post(c.state, connections_posted, list) {
		delete(list^)
		free(list)
	}
}

// On the window's thread: a new reading becomes the rows.
@(private = "file")
connections_posted :: proc(data: rawptr, _: u64) {
	list := (^[dynamic]Socket)(data)
	defer free(list)
	if the_app == nil { delete(list^); return }
	c := &the_app.connections
	delete(c.sockets)
	c.sockets = list^
	c.read = true
	connections_count(c)
	connections_rows(the_app)
}

// A process and how many sockets it holds.
Socket_Holder :: struct { pid: i32, start: u64, n: int }

// The sockets that listen, those connected, and their holders, the most first.
@(private = "file")
connections_count :: proc(c: ^Connections) {
	c.listening, c.connected = 0, 0
	clear(&c.holders)
	at := make(map[i32]int, 16, context.temp_allocator)
	for so in c.sockets {
		if so.state == .Listening { c.listening += 1 } else if so.state == .Established { c.connected += 1 }
		if so.pid <= 0 { continue }
		i, seen := at[so.pid]
		if !seen {
			i = len(c.holders)
			at[so.pid] = i
			append(&c.holders, Socket_Holder{pid = so.pid, start = so.start})
		}
		c.holders[i].n += 1
	}
	slice.sort_by(c.holders[:], proc(a, b: Socket_Holder) -> bool { return a.n > b.n })
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

// The sockets are read on their own period (connections.refresh_ms), not at each sample of the processes: a reading
// goes through every process's open files. Only while they are shown: their section, Mission Control or one of its
// panels in a window.
connections_shown :: proc(app: ^App) -> bool {
	return app.tab == .Connections || app.tab == .Mission_Control || len(app.mission_windows) > 0
}

// A reading now (the section shown, F5), the next one a period later.
connections_ask :: proc(app: ^App) {
	tasks.ask(ui.chores(), &app.connections.job)
	app.connections.next = time.tick_add(time.tick_now(), time.Duration(app.settings.connections_ms) * time.Millisecond)
}

// Each turn of the loop (not while the refresh is paused): a reading when one is due and they are shown.
connections_tick :: proc(app: ^App) {
	if !connections_shown(app) || tasks.busy(ui.chores(), &app.connections.job) { return }
	if time.tick_diff(app.connections.next, time.tick_now()) >= 0 { connections_ask(app) }
}

// The milliseconds until the next reading is due, while they are shown (the window wakes for it); max(int) otherwise.
connections_due_ms :: proc(app: ^App) -> int {
	if !connections_shown(app) || app.paused || app.held { return max(int) }
	return max(int(time.duration_milliseconds(time.tick_diff(time.tick_now(), app.connections.next))) + 1, 1)
}
