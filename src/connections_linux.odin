package inspecteur

// The sockets on Linux: /proc/net/tcp, tcp6, udp and udp6, and each socket's process by its inode: /proc/<pid>/fd/<n>
// links to "socket:[<inode>]". Only the processes the user can read are told: another user's sockets have none.
//
// Socket_Reader keeps /proc and /proc/net/* descriptors open (lseek(0) + read loop for multi-page seq_files).
// owners_scan opens <pid>/fd first so kernel threads and other users' processes fail in one syscall without reading
// stat; for processes that hold sockets, ../stat is read relative to the open fd/ descriptor (pinned to the same
// process). A reading whose sockets are all known skips the scan (at most OWNER_SCAN_EVERY readings in a row); when
// new socket inodes appear before the periodic full scan, an incremental scan stops as soon as every unknown inode is
// found.

import "core:slice"
import "core:strings"
import "core:sys/linux"

// Readings in a row that can skip the full scan of every process's descriptors when no new socket asks for one.
OWNER_SCAN_EVERY :: 10
// The bytes of a /proc/net file read at most (a busy server's thousands of sockets).
NET_FILE_MAX :: 4 * 1024 * 1024

Owner :: struct { pid: i32, start: u64 }

Socket_Reader :: struct {
	owners:   map[u64]Owner,      // inode -> process, from the last scan
	unowned:  map[u64]bool,       // the inodes the last scan found no owner for: known too
	need:     map[u64]struct{},   // unknown inodes sought by an incremental scan
	skipped:  int,                // readings since the last full scan
	buf:      []u8,
	dents:    []u8,               // 64 KB getdents buffer, reused across scans
	pids:     [dynamic]i32,
	found:    [dynamic]u64,
	fds_init: bool,
	proc_dir: linux.Fd,
	net_fds:  [4]linux.Fd,
}

socket_reader_destroy :: proc(r: ^Socket_Reader) {
	if r.fds_init {
		if r.proc_dir >= 0 { linux.close(r.proc_dir) }
		for fd in r.net_fds { if fd >= 0 { linux.close(fd) } }
	}
	delete(r.owners)
	delete(r.unowned)
	delete(r.need)
	delete(r.buf)
	delete(r.dents)
	delete(r.pids)
	delete(r.found)
	r^ = {}
}

@(private = "file")
socket_reader_ensure :: proc(r: ^Socket_Reader) {
	if !r.fds_init {
		r.fds_init = true
		r.proc_dir = -1
		r.net_fds = {-1, -1, -1, -1}
	}
	if r.buf == nil { r.buf = make([]u8, NET_FILE_MAX) }
	if r.dents == nil { r.dents = make([]u8, 64 * 1024) }
	if r.proc_dir < 0 {
		if fd, err := linux.open("/proc", {.DIRECTORY, .CLOEXEC}); err == .NONE { r.proc_dir = fd }
	}
}

@(private = "file")
read_net_kept :: proc(fd: ^linux.Fd, path: cstring, buf: []u8) -> (data: []u8, ok: bool) {
	for _ in 0 ..< 2 {
		if fd^ < 0 {
			f, err := linux.open(path, {.CLOEXEC})
			if err != .NONE { return nil, false }
			fd^ = f
		}
		if _, lerr := linux.lseek(fd^, 0, .SET); lerr == .NONE {
			n := 0
			good := true
			for n < len(buf) {
				k, re := linux.read(fd^, buf[n:])
				if re != .NONE { good = false; break }
				if k <= 0 { break }
				n += k
			}
			if good { return buf[:n], true }
		}
		linux.close(fd^)
		fd^ = -1
	}
	return nil, false
}

// Every socket now, with its process when it can be told (temporary allocations; `out` in its own allocator).
sockets_read :: proc(r: ^Socket_Reader, out: ^[dynamic]Socket) {
	socket_reader_ensure(r)
	FILES :: [4]struct { path: cstring, proto: Proto, v6: bool }{
		{"/proc/net/tcp", .TCP, false}, {"/proc/net/tcp6", .TCP, true}, {"/proc/net/udp", .UDP, false}, {"/proc/net/udp6", .UDP, true},
	}
	for f, idx in FILES {
		if data, ok := read_net_kept(&r.net_fds[idx], f.path, r.buf); ok {
			parse_net_sockets(string(data), f.proto, f.v6, out)
		}
	}
	clear(&r.need)
	for s in out {
		if s.key != 0 && s.key not_in r.owners && s.key not_in r.unowned { r.need[s.key] = {} }
	}
	if r.skipped >= OWNER_SCAN_EVERY || (len(r.need) > 0 && len(r.owners) == 0 && len(r.unowned) == 0) {
		owners_scan(r, incremental = false)
		r.skipped = 0
		clear(&r.unowned)
		for s in out { if s.key != 0 && s.key not_in r.owners { r.unowned[s.key] = true } }
	} else if len(r.need) > 0 {
		// Incremental scan: resolve newly appeared socket inodes without rescanning all processes once found.
		owners_scan(r, incremental = true)
		for inode in r.need { r.unowned[inode] = true }
		r.skipped += 1
	} else {
		r.skipped += 1
	}
	for &s in out {
		if o, ok := r.owners[s.key]; ok && s.key != 0 { s.pid, s.start = o.pid, o.start }
	}
}

@(private = "file")
socket_pid_path :: proc(dst: []u8, pid: i32, suffix: string) -> cstring {
	tmp: [16]u8
	v := u32(pid)
	d := len(tmp)
	if v == 0 {
		d -= 1
		tmp[d] = '0'
	} else {
		for v > 0 {
			d -= 1
			tmp[d] = u8('0' + v % 10)
			v /= 10
		}
	}
	n := copy(dst, tmp[d:])
	n += copy(dst[n:], suffix)
	dst[n] = 0
	return cstring(&dst[0])
}

// Every process's socket inodes (the processes the user can read).
@(private = "file")
owners_scan :: proc(r: ^Socket_Reader, incremental: bool) {
	if !incremental { clear(&r.owners) }
	if r.proc_dir < 0 { return }
	clear(&r.pids)
	if _, err := linux.lseek(r.proc_dir, 0, .SET); err != .NONE { return }
	for {
		n, e := linux.getdents(r.proc_dir, r.dents)
		if e != .NONE || n <= 0 { break }
		offs := 0
		for d in linux.dirent_iterate_buf(r.dents[:n], &offs) {
			name := linux.dirent_name(d)
			if len(name) == 0 || name[0] < '0' || name[0] > '9' { continue }
			pid: i32
			valid := true
			for b in transmute([]u8)name {
				if b < '0' || b > '9' { valid = false; break }
				pid = pid * 10 + i32(b - '0')
			}
			if valid && pid > 0 { append(&r.pids, pid) }
		}
	}
	// Ascending pid order guarantees deterministic lowest-pid ownership for sockets shared after a fork.
	slice.sort(r.pids[:])

	link: [64]u8
	stat_buf: [1024]u8
	pb: [32]u8
	for pid in r.pids {
		if incremental && len(r.need) == 0 { break }
		// Open <pid>/fd first: kernel threads and other users' processes fail here in one syscall without touching stat.
		dfd, err := linux.openat(r.proc_dir, socket_pid_path(pb[:], pid, "/fd"), {.DIRECTORY, .CLOEXEC})
		if err != .NONE { continue }
		clear(&r.found)
		for {
			n, derr := linux.getdents(dfd, r.dents)
			if derr != .NONE || n <= 0 { break }
			off := 0
			for off < n {
				d := (^linux.Dirent)(&r.dents[off])
				off += int(d.reclen)
				name := linux.dirent_name(d)
				if len(name) == 0 || name[0] == '.' { continue }
				// (the entry's name ends with a NUL in the buffer: it is a C string as it is)
				k, lerr := linux.readlinkat(dfd, cstring(raw_data(name)), link[:])
				if lerr != .NONE || k < 10 { continue }
				if link[0] != 's' || string(link[:8]) != "socket:[" || link[k - 1] != ']' { continue }
				if inode, ok := parse_ascii_u64(string(link[8:k - 1])); ok {
					if !incremental || inode in r.need { append(&r.found, inode) }
				}
			}
		}
		if len(r.found) > 0 {
			// ../stat relative to the open fd/ descriptor stays pinned to the exact same process (no pid-reuse race).
			if sfd, serr := linux.openat(dfd, "../stat", {.CLOEXEC}); serr == .NONE {
				sn, sre := linux.read(sfd, stat_buf[:])
				linux.close(sfd)
				if sre == .NONE && sn > 0 {
					if st, pok := parse_stat(string(stat_buf[:sn])); pok {
						for inode in r.found {
							if inode not_in r.owners { r.owners[inode] = Owner{pid, st.start} }
							if incremental { delete_key(&r.need, inode) }
						}
					}
				}
			}
		}
		linux.close(dfd)
	}
}

// The lines of /proc/net/tcp (tcp6, udp, udp6), after its title line:
//   "   0: 0100007F:0277 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 23456 1 ..."
// An address is the kernel's 32-bit words in hexadecimal, each in the machine's byte order (little-endian here):
// 0100007F is 127.0.0.1. A port is big-endian hexadecimal. The state is the kernel's number (TCP_ESTABLISHED = 1...).
parse_net_sockets :: proc(text: string, proto: Proto, v6: bool, out: ^[dynamic]Socket) {
	i := 0
	n := len(text)
	// Skip title line
	for i < n && text[i] != '\n' { i += 1 }
	if i < n { i += 1 }
	for i < n {
		start := i
		for i < n && text[i] != '\n' { i += 1 }
		line := text[start:i]
		if i < n { i += 1 }
		pos := 0
		if _, has := next_token(line, &pos); !has { continue } // field 0: sl
		w1, ok1 := next_token(line, &pos)
		w2, ok2 := next_token(line, &pos)
		w3, ok3 := next_token(line, &pos)
		if !ok1 || !ok2 || !ok3 { continue }
		// Skip fields 4..8 (queues, timer, retrnsmt, uid, timeout)
		skip_ok := true
		for _ in 4 ..< 9 {
			if _, has := next_token(line, &pos); !has { skip_ok = false; break }
		}
		if !skip_ok { continue }
		w9, ok9 := next_token(line, &pos)
		if !ok9 { continue }

		s := Socket{proto = proto, v6 = v6}
		if !parse_endpoint(w1, v6, &s.local, &s.lport) { continue }
		if !parse_endpoint(w2, v6, &s.remote, &s.rport) { continue }
		st_v, st_ok := parse_hex_u64(w3)
		if !st_ok { continue }
		s.state = socket_state_of(proto, st_v)
		ino, ino_ok := parse_ascii_u64(w9)
		if !ino_ok { continue }
		s.key = ino
		append(out, s)
	}
}

@(private = "file")
hex_val :: proc(c: u8) -> (v: u8, ok: bool) {
	switch c {
	case '0' ..= '9': return c - '0', true
	case 'a' ..= 'f': return c - 'a' + 10, true
	case 'A' ..= 'F': return c - 'A' + 10, true
	}
	return 0, false
}

@(private = "file")
parse_hex_u64 :: proc(s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 || len(s) > 16 { return 0, false }
	for i in 0 ..< len(s) {
		d, dok := hex_val(s[i])
		if !dok { return 0, false }
		v = (v << 4) | u64(d)
	}
	return v, true
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
		v, ok := parse_hex_u64(hex[k * 8:][:8])
		if !ok { return false }
		// (the word in the machine's order: its lowest byte is the address's first)
		for b in 0 ..< 4 { addr[k * 4 + b] = u8(v >> (8 * uint(b))) }
	}
	pv, pok := parse_hex_u64(p)
	port^ = u16(pv)
	return pok
}
