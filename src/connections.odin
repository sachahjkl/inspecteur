package inspecteur

// The Connections section's reading: the TCP and UDP sockets of the machine, IPv4 and IPv6 (/proc/net/tcp, tcp6, udp,
// udp6), each with the process that holds it. A socket's process is found by its inode: /proc/<pid>/fd/<n> links to
// "socket:[<inode>]". Only the processes the user may read can be told: another user's sockets show no process.
//
// Reading every process's descriptors costs some milliseconds, so it is done on a thread of its own (worker.odin), and
// only while the section is shown. A reading whose sockets all have a known owner skips that scan (at most
// OWNER_SCAN_EVERY readings in a row); a new socket brings it back.

import "core:net"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import lucide "gt:lucide"
import "gt:ui"

// Readings in a row that may skip the scan of every process's descriptors when no new socket asks for one.
OWNER_SCAN_EVERY :: 10
// The bytes of a /proc/net file read at most (a busy server's thousands of sockets).
NET_FILE_MAX :: 4 * 1024 * 1024

Proto :: enum u8 { TCP, UDP }

Socket :: struct {
	proto:  Proto,
	v6:     bool,
	local:  [16]u8,   // IPv4: the first 4 bytes
	remote: [16]u8,
	lport, rport: u16,
	state:  u8,       // the kernel's TCP state (1 established ... 10 listen); UDP: 1 connected, 7 not
	uid:    u32,
	inode:  u64,
	pid:    i32,      // the process that holds it; 0: not known (another user's, or a socket in TIME_WAIT)
	start:  u64,      // and its start time (its identity, for End task)
}

Owner :: struct { pid: i32, start: u64 }

Connections :: struct {
	worker:   Worker,
	shared:   [dynamic]Socket,   // the worker's last reading, under its mutex
	sockets:  [dynamic]Socket,   // the window's copy
	data:     Grid_Data,
	grid:     Grid,
	read:     bool,              // a reading came at least once
	menu:     ui.Key,
	// the worker's own
	owners:   map[u64]Owner,     // inode -> process, from the last scan
	skipped:  int,               // readings since the last scan
	buf:      []u8,
}

CONN_COLUMNS := [?]Grid_Column{
	{title = "Process", width = 0},
	{title = "PID", width = 5.5, number = true, weak = true},
	{title = "Protocol", width = 6},
	{title = "Local address", width = 17},
	{title = "Remote address", width = 17},
	{title = "State", width = 8.5, weak = true},
}

connections_init :: proc(c: ^Connections, app: ^App) {
	grid_init(&c.grid, CONN_COLUMNS[:])
	worker_start(&c.worker, connections_job, c, app.main.win)
}

connections_destroy :: proc(c: ^Connections) {
	worker_stop(&c.worker)
	delete(c.shared)
	delete(c.sockets)
	delete(c.owners)
	delete(c.buf)
	grid_data_destroy(&c.data)
	grid_destroy(&c.grid)
}

@(private = "file")
connections_job :: proc(w: ^Worker) {
	c := (^Connections)(w.user)
	if c.buf == nil { c.buf = make([]u8, NET_FILE_MAX) }
	list := make([dynamic]Socket, context.temp_allocator)
	FILES :: [4]struct { path: string, proto: Proto, v6: bool }{
		{"/proc/net/tcp", .TCP, false}, {"/proc/net/tcp6", .TCP, true}, {"/proc/net/udp", .UDP, false}, {"/proc/net/udp6", .UDP, true},
	}
	for f in FILES {
		data, _, ok := read_file(c.buf, linux.AT_FDCWD, f.path)
		if ok { parse_net_sockets(string(data), f.proto, f.v6, &list) }
	}
	// a scan when a socket's owner is not known, or the last one is old
	unknown := false
	for s in list { if s.inode != 0 && s.inode not_in c.owners { unknown = true; break } }
	if unknown || c.skipped >= OWNER_SCAN_EVERY {
		owners_scan(&c.owners)
		c.skipped = 0
	} else {
		c.skipped += 1
	}
	for &s in list {
		if o, ok := c.owners[s.inode]; ok && s.inode != 0 { s.pid, s.start = o.pid, o.start }
	}
	worker_lock(w)
	clear(&c.shared)
	append(&c.shared, ..list[:])
	worker_unlock(w)
	worker_published(w)
}

// Every process's socket inodes (the processes the user may read): /proc/<pid>/fd/* that link to socket:[inode].
@(private = "file")
owners_scan :: proc(owners: ^map[u64]Owner) {
	clear(owners)
	pids := make([dynamic]i32, context.temp_allocator)
	list_pids(&pids)
	dents: [8192]u8
	link: [64]u8
	path: [64]u8
	stat_buf: [1024]u8
	for pid in pids {
		dir_path := strings.concatenate({"/proc/", pid_text(pid), "/fd"}, context.temp_allocator)
		copy(path[:], dir_path)
		path[len(dir_path)] = 0
		fd, err := linux.open(cstring(&path[0]), {.DIRECTORY, .CLOEXEC})
		if err != .NONE { continue }   // (another user's: EACCES)
		start: u64
		has_start := false
		for {
			n, derr := linux.getdents(fd, dents[:])
			if derr != .NONE || n <= 0 { break }
			off := 0
			for off < n {
				d := (^linux.Dirent)(&dents[off])
				off += int(d.reclen)
				name := linux.dirent_name(d)
				if name == "." || name == ".." { continue }
				// (the entry's name ends with a NUL in the buffer: it is a C string as it is)
				k, lerr := linux.readlinkat(fd, cstring(raw_data(name)), link[:])
				if lerr != .NONE { continue }
				target := string(link[:k])
				if !strings.has_prefix(target, "socket:[") || !strings.has_suffix(target, "]") { continue }
				inode, ok := strconv.parse_u64(target[8:len(target) - 1], 10)
				if !ok { continue }
				if !has_start {
					has_start = true
					stat_path := strings.concatenate({"/proc/", pid_text(pid), "/stat"}, context.temp_allocator)
					if data, _, sok := read_file(stat_buf[:], linux.AT_FDCWD, stat_path); sok {
						if st, pok := parse_stat(string(data)); pok { start = st.start }
					}
				}
				// (a socket two processes share, after a fork: the first one met, the lower pid, keeps it)
				if inode not_in owners^ { owners[inode] = Owner{pid, start} }
			}
		}
		linux.close(fd)
	}
}

@(private = "file")
pid_text :: proc(pid: i32) -> string {
	buf: [16]u8
	return strings.clone(strconv.write_int(buf[:], i64(pid), 10), context.temp_allocator)
}

// The window's turn: a new reading becomes the rows.
connections_take :: proc(app: ^App) {
	c := &app.connections
	if !worker_take(&c.worker) { return }
	worker_lock(&c.worker)
	clear(&c.sockets)
	append(&c.sockets, ..c.shared[:])
	worker_unlock(&c.worker)
	c.read = true
	connections_rows(app)
}

// The rows again from the sockets (a reading, a new sample of the processes' names).
connections_rows :: proc(app: ^App) {
	c := &app.connections
	d := &c.data
	grid_data_reset(d, len(CONN_COLUMNS))
	for s in c.sockets {
		name := "—"
		pid := ""
		icon := Grid_Icon{glyph = lucide.SQUARE_TERMINAL}
		if s.pid > 0 {
			pid = pid_text(s.pid)
			name = pid
			if p := find_proc(&app.sampler, s.pid, s.start); p != nil {
				name = p.name
				if p.entry >= 0 { icon.app = app.catalog.entries[p.entry].icon }
			}
		}
		proto := s.proto == .TCP ? "TCP" : "UDP"
		local := endpoint_text(s.local, s.lport, s.v6)
		remote := remote_text(s)
		state := socket_state_text(s)
		grid_row(d, socket_id(s), strings.join({name, pid, proto, local, remote, state}, " ", context.temp_allocator), icon, s.pid > 0 ? .Normal : .Dim)
		grid_cell(d, name)
		grid_cell(d, pid, f64(s.pid))
		grid_cell(d, s.v6 ? (s.proto == .TCP ? "TCPv6" : "UDPv6") : proto)
		grid_cell(d, local)
		grid_cell(d, remote)
		grid_cell(d, state)
	}
	grid_apply(&c.grid, d, app.query)
}

// A socket's identity across readings: its inode, else (TIME_WAIT has none) its addresses.
socket_id :: proc(s: Socket) -> u64 {
	if s.inode != 0 { return s.inode | 1 << 63 }
	h: u64 = 14695981039346656037
	mix :: proc(h: ^u64, b: u8) { h^ = (h^ ~ u64(b)) * 1099511628211 }
	for b in s.local { mix(&h, b) }
	for b in s.remote { mix(&h, b) }
	mix(&h, u8(s.lport)); mix(&h, u8(s.lport >> 8)); mix(&h, u8(s.rport)); mix(&h, u8(s.rport >> 8))
	mix(&h, u8(s.proto)); mix(&h, u8(s.v6))
	return h & ~(u64(1) << 63)
}

// "127.0.0.1:631", "[::1]:631", "*:68" (any address).
endpoint_text :: proc(addr: [16]u8, port: u16, v6: bool) -> string {
	host: string
	zero := true
	a := addr
	for b in a[:v6 ? 16 : 4] { if b != 0 { zero = false } }
	if zero {
		host = "*"
	} else if v6 {
		a: net.IP6_Address
		for i in 0 ..< 8 { a[i] = u16be(u16(addr[2 * i]) << 8 | u16(addr[2 * i + 1])) }
		host = strings.concatenate({"[", net.address_to_string(a, context.temp_allocator), "]"}, context.temp_allocator)
	} else {
		host = net.address_to_string(net.IP4_Address{addr[0], addr[1], addr[2], addr[3]}, context.temp_allocator)
	}
	buf: [8]u8
	return strings.concatenate({host, ":", port == 0 ? "*" : strconv.write_uint(buf[:], u64(port), 10)}, context.temp_allocator)
}

// The remote end: none for a socket that listens or waits for datagrams from anyone.
remote_text :: proc(s: Socket) -> string {
	zero := s.rport == 0
	for b in s.remote { if b != 0 { zero = false } }
	if zero { return "" }
	return endpoint_text(s.remote, s.rport, s.v6)
}

TCP_STATES := [?]string{"", "Established", "SYN sent", "SYN received", "FIN wait 1", "FIN wait 2", "Time wait", "Closed", "Close wait", "Last ACK", "Listening", "Closing", "SYN received"}

socket_state_text :: proc(s: Socket) -> string {
	if s.proto == .UDP { return s.state == 1 ? "Connected" : "Open" }
	return int(s.state) < len(TCP_STATES) ? TCP_STATES[s.state] : "?"
}

// The lines of /proc/net/tcp (tcp6, udp, udp6), after its title line:
//   "   0: 0100007F:0277 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 23456 1 ..."
// An address is the kernel's 32-bit words in hexadecimal, each in the machine's byte order (little-endian here):
// 0100007F is 127.0.0.1. A port is big-endian hexadecimal.
parse_net_sockets :: proc(text: string, proto: Proto, v6: bool, out: ^[dynamic]Socket) {
	rest := text
	first := true
	for line in strings.split_lines_iterator(&rest) {
		if first { first = false; continue }
		s := Socket{proto = proto, v6 = v6}
		field := 0
		words := line
		ok := true
		for word in strings.fields_iterator(&words) {
			switch field {
			case 1: ok = ok && parse_endpoint(word, v6, &s.local, &s.lport)
			case 2: ok = ok && parse_endpoint(word, v6, &s.remote, &s.rport)
			case 3:
				v, vok := strconv.parse_u64(word, 16)
				s.state = u8(v)
				ok = ok && vok
			case 7:
				v, vok := strconv.parse_u64(word, 10)
				s.uid = u32(v)
				ok = ok && vok
			case 9:
				v, vok := strconv.parse_u64(word, 10)
				s.inode = v
				ok = ok && vok
			}
			field += 1
		}
		if ok && field >= 10 { append(out, s) }
	}
}

@(private = "file")
parse_endpoint :: proc(word: string, v6: bool, addr: ^[16]u8, port: ^u16) -> bool {
	colon := strings.index_byte(word, ':')
	if colon < 0 { return false }
	hex, p := word[:colon], word[colon + 1:]
	words := v6 ? 4 : 1
	if len(hex) != words * 8 { return false }
	for k in 0 ..< words {
		v, ok := strconv.parse_u64(hex[k * 8:][:8], 16)
		if !ok { return false }
		// (the word in the machine's order: its lowest byte is the address's first)
		for b in 0 ..< 4 { addr[k * 4 + b] = u8(v >> (8 * uint(b))) }
	}
	pv, pok := strconv.parse_u64(p, 16)
	port^ = u16(pv)
	return pok
}
