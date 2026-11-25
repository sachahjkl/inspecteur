package inspecteur

// Windows session guards: locate dwm.exe in the current interactive session so Inspecteur never suspends
// Desktop Window Manager and warns before terminating it.

import "core:strings"
import win "core:sys/windows"
import winapi "winapi"

own_units :: proc() -> []string { return nil }

display_server_pid :: proc() -> i32 {
	d := win_dyn()
	if d.NtQuerySystemInformation == nil { return 0 }
	my_session: win.DWORD
	if d.ProcessIdToSessionId != nil {
		_ = d.ProcessIdToSessionId(win.GetCurrentProcessId(), &my_session)
	}
	buf := make([]u8, 256 * 1024)
	defer delete(buf)
	for attempt in 0 ..< 8 {
		ret: u32
		st := d.NtQuerySystemInformation(WIN_NT_SYSTEM_PROCESS_INFO, raw_data(buf), u32(len(buf)), &ret)
		if st == winapi.STATUS_SUCCESS {
			procs := make([dynamic]winapi.Decoded_Process, context.temp_allocator)
			if winapi.decode_system_processes(buf, u64(uintptr(raw_data(buf))), &procs) {
				for p in procs {
					if p.pid <= 0 { continue }
					if p.session_id == u32(my_session) && strings.equal_fold(p.name, "dwm.exe") {
						return p.pid
					}
				}
			}
			return 0
		}
		if st != winapi.STATUS_INFO_LENGTH_MISMATCH { return 0 }
		next, ok := winapi.next_buffer_size(len(buf), ret)
		if !ok { return 0 }
		delete(buf)
		buf = make([]u8, next)
		_ = attempt
	}
	return 0
}
