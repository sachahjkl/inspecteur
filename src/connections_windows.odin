package inspecteur

// Windows TCP and UDP connections (IPv4 and IPv6) via GetExtendedTcpTable / GetExtendedUdpTable
// from iphlpapi.dll, with owning PIDs matched to creation times from one SystemProcessInformation call.

import "core:sync"
import win "core:sys/windows"
import winapi "winapi"

@(private = "file") TCP_TABLE_OWNER_PID_ALL :: u32(5)
@(private = "file") UDP_TABLE_OWNER_PID     :: u32(1)
@(private = "file") WIN_AF_INET             :: u32(2)
@(private = "file") WIN_AF_INET6            :: u32(23)

@(private = "file")
Win_Ip_Procs :: struct {
	GetExtendedTcpTable: proc "system" (buf: rawptr, size: ^win.DWORD, order: win.BOOL, af: u32, class: u32, reserved: u32) -> win.DWORD,
	GetExtendedUdpTable: proc "system" (buf: rawptr, size: ^win.DWORD, order: win.BOOL, af: u32, class: u32, reserved: u32) -> win.DWORD,
}

@(private = "file") win_ip_once: sync.Once
@(private = "file") win_ip_procs: Win_Ip_Procs

@(private = "file")
win_ip :: proc() -> ^Win_Ip_Procs {
	sync.once_do(&win_ip_once, proc() {
		if ip := win_system_library("iphlpapi.dll"); ip != nil {
			win_ip_procs.GetExtendedTcpTable = auto_cast win.GetProcAddress(ip, "GetExtendedTcpTable")
			win_ip_procs.GetExtendedUdpTable = auto_cast win.GetProcAddress(ip, "GetExtendedUdpTable")
		}
	})
	return &win_ip_procs
}

Socket_Reader :: struct {
	buf:      []u8,        // reused growing buffer for IP Helper tables
	proc_buf: []u8,        // reused buffer for PID -> creation time resolution
	starts:   map[i32]u64,
}

socket_reader_destroy :: proc(r: ^Socket_Reader) {
	delete(r.buf)
	delete(r.proc_buf)
	delete(r.starts)
	r^ = {}
}

sockets_read :: proc(r: ^Socket_Reader, out: ^[dynamic]Socket) {
	ip := win_ip()
	if ip.GetExtendedTcpTable == nil && ip.GetExtendedUdpTable == nil { return }
	if len(r.buf) < 64 * 1024 {
		delete(r.buf)
		r.buf = make([]u8, 64 * 1024)
	}

	// Build PID -> creation time map in one kernel call so every Socket carries verified (pid, start).
	clear(&r.starts)
	if win_query_system_processes(&r.proc_buf) {
		procs := make([dynamic]winapi.Decoded_Process, 0, 256, context.temp_allocator)
		if winapi.decode_system_processes(r.proc_buf, u64(uintptr(raw_data(r.proc_buf))), &procs) {
			for dp in procs {
				if dp.pid > 0 { r.starts[dp.pid] = dp.create_time }
			}
		}
	}

	decoded := make([dynamic]winapi.Decoded_Socket, 0, 128, context.temp_allocator)
	if ip.GetExtendedTcpTable != nil {
		if raw, ok := query_tcp_table(ip, &r.buf, WIN_AF_INET); ok {
			winapi.decode_tcp4_table(raw, &decoded)
		}
		if raw, ok := query_tcp_table(ip, &r.buf, WIN_AF_INET6); ok {
			winapi.decode_tcp6_table(raw, &decoded)
		}
	}
	if ip.GetExtendedUdpTable != nil {
		if raw, ok := query_udp_table(ip, &r.buf, WIN_AF_INET); ok {
			winapi.decode_udp4_table(raw, &decoded)
		}
		if raw, ok := query_udp_table(ip, &r.buf, WIN_AF_INET6); ok {
			winapi.decode_udp6_table(raw, &decoded)
		}
	}

	for ds in decoded {
		proto := ds.udp ? Proto.UDP : Proto.TCP
		state := ds.udp ? Socket_State.Open : win_tcp_state(ds.mib_state)
		append(out, Socket{
			proto  = proto,
			v6     = ds.v6,
			local  = ds.local,
			remote = ds.remote,
			lport  = ds.lport,
			rport  = ds.rport,
			state  = state,
			pid    = ds.pid,
			start  = r.starts[ds.pid],
		})
	}
}

@(private = "file")
query_tcp_table :: proc(ip: ^Win_Ip_Procs, buf: ^[]u8, af: u32) -> ([]u8, bool) {
	for _ in 0 ..< 6 {
		sz := win.DWORD(len(buf^))
		rc := ip.GetExtendedTcpTable(raw_data(buf^), &sz, false, af, TCP_TABLE_OWNER_PID_ALL, 0)
		if rc == 0 { return buf^[:min(int(sz), len(buf^))], true }
		if rc != win.ERROR_INSUFFICIENT_BUFFER { return nil, false }
		next, ok := winapi.next_buffer_size(len(buf^), u32(sz))
		if !ok { return nil, false }
		delete(buf^)
		buf^ = make([]u8, next)
	}
	return nil, false
}

@(private = "file")
query_udp_table :: proc(ip: ^Win_Ip_Procs, buf: ^[]u8, af: u32) -> ([]u8, bool) {
	for _ in 0 ..< 6 {
		sz := win.DWORD(len(buf^))
		rc := ip.GetExtendedUdpTable(raw_data(buf^), &sz, false, af, UDP_TABLE_OWNER_PID, 0)
		if rc == 0 { return buf^[:min(int(sz), len(buf^))], true }
		if rc != win.ERROR_INSUFFICIENT_BUFFER { return nil, false }
		next, ok := winapi.next_buffer_size(len(buf^), u32(sz))
		if !ok { return nil, false }
		delete(buf^)
		buf^ = make([]u8, next)
	}
	return nil, false
}

@(private = "file")
win_tcp_state :: proc(mib: u32) -> Socket_State {
	switch mib {
	case 1:  return .Closed       // MIB_TCP_STATE_CLOSED
	case 2:  return .Listening    // MIB_TCP_STATE_LISTEN
	case 3:  return .Syn_Sent     // MIB_TCP_STATE_SYN_SENT
	case 4:  return .Syn_Received // MIB_TCP_STATE_SYN_RCVD
	case 5:  return .Established  // MIB_TCP_STATE_ESTAB
	case 6:  return .Fin_Wait_1   // MIB_TCP_STATE_FIN_WAIT1
	case 7:  return .Fin_Wait_2   // MIB_TCP_STATE_FIN_WAIT2
	case 8:  return .Close_Wait   // MIB_TCP_STATE_CLOSE_WAIT
	case 9:  return .Closing      // MIB_TCP_STATE_CLOSING
	case 10: return .Last_Ack     // MIB_TCP_STATE_LAST_ACK
	case 11: return .Time_Wait    // MIB_TCP_STATE_TIME_WAIT
	case 12: return .Closed       // MIB_TCP_STATE_DELETE_TCB
	}
	return .Unknown
}
