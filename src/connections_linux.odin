package inspecteur

// The sockets on Linux: /proc/net/tcp, tcp6, udp and udp6, and each socket's process by its inode: /proc/<pid>/fd/<n>
// links to "socket:[<inode>]". Only the processes the user may read can be told: another user's sockets have none.
//
// The scan of every process's descriptors is what costs; a reading whose sockets all have a known owner skips it (at
// most OWNER_SCAN_EVERY readings in a row); a new socket brings it back.

import "core:strconv"
import "core:strings"
import "core:sys/linux"

// Readings in a row that may skip the scan of every process's descriptors when no new socket asks for one.
OWNER_SCAN_EVERY :: 10
// The bytes of a /proc/net file read at most (a busy server's thousands of sockets).
NET_FILE_MAX :: 4 * 1024 * 1024

Owner :: struct { pid: i32, start: u64 }

Socket_Reader :: struct {
	owners:  map[u64]Owner,   // inode -> process, from the last scan
	skipped: int,             // readings since the last scan
	buf:     []u8,
}

socket_reader_destroy :: proc(r: ^Socket_Reader) {
	delete(r.owners)
	delete(r.buf)
}

// Every socket now, with its process when it can be told (temporary allocations; `out` in its own allocator).
sockets_read :: proc(r: ^Socket_Reader, out: ^[dynamic]Socket) {
	if r.buf == nil { r.buf = make([]u8, NET_FILE_MAX) }
	FILES :: [4]struct { path: string, proto: Proto, v6: bool }{
		{"/proc/net/tcp", .TCP, false}, {"/proc/net/tcp6", .TCP, true}, {"/proc/net/udp", .UDP, false}, {"/proc/net/udp6", .UDP, true},
	}
	for f in FILES {
		data, _, ok := read_file(r.buf, linux.AT_FDCWD, f.path)
		if ok { parse_net_sockets(string(data), f.proto, f.v6, out) }
	}
	unknown := false
	for s in out { if s.key != 0 && s.key not_in r.owners { unknown = true; break } }
	if unknown || r.skipped >= OWNER_SCAN_EVERY {
		owners_scan(&r.owners)
		r.skipped = 0
	} else {
		r.skipped += 1
	}
	for &s in out {
		if o, ok := r.owners[s.key]; ok && s.key != 0 { s.pid, s.start = o.pid, o.start }
	}
}

// Every process's socket inodes (the processes the user may read).
@(private = "file")
owners_scan :: proc(owners: ^map[u64]Owner) {
	clear(owners)
	pids := make([dynamic]i32, context.temp_allocator)
	list_pids(&pids)
	dents: [8192]u8
	link: [64]u8
	stat_buf: [1024]u8
	num: [16]u8
	for pid in pids {
		pid_s := strconv.write_int(num[:], i64(pid), 10)
		dir := strings.clone_to_cstring(strings.concatenate({"/proc/", pid_s, "/fd"}, context.temp_allocator), context.temp_allocator)
		fd, err := linux.open(dir, {.DIRECTORY, .CLOEXEC})
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
					stat_path := strings.concatenate({"/proc/", pid_s, "/stat"}, context.temp_allocator)
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

// The lines of /proc/net/tcp (tcp6, udp, udp6), after its title line:
//   "   0: 0100007F:0277 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 23456 1 ..."
// An address is the kernel's 32-bit words in hexadecimal, each in the machine's byte order (little-endian here):
// 0100007F is 127.0.0.1. A port is big-endian hexadecimal. The state is the kernel's number (TCP_ESTABLISHED = 1...).
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
				s.state = socket_state_of(proto, v)
				ok = ok && vok
			case 9:
				v, vok := strconv.parse_u64(word, 10)
				s.key = v
				ok = ok && vok
			}
			field += 1
		}
		if ok && field >= 10 { append(out, s) }
	}
}

// The kernel's TCP states (include/net/tcp_states.h); a UDP socket is 1 (connected) or 7 (not).
@(private = "file")
socket_state_of :: proc(proto: Proto, v: u64) -> Socket_State {
	if proto == .UDP { return v == 1 ? .Connected : .Open }
	switch v {
	case 1:  return .Established
	case 2:  return .Syn_Sent
	case 3:  return .Syn_Received
	case 4:  return .Fin_Wait_1
	case 5:  return .Fin_Wait_2
	case 6:  return .Time_Wait
	case 7:  return .Closed
	case 8:  return .Close_Wait
	case 9:  return .Last_Ack
	case 10: return .Listening
	case 11: return .Closing
	case 12: return .Syn_Received   // (TCP_NEW_SYN_RECV)
	}
	return .Unknown
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
