package winapi

// Pure decoders for Windows NT and Win32 binary buffers, registry values, SMBIOS, EDID,
// Shell Link (.lnk) files, Task Scheduler XML, PDH GPU counter instance strings, and svchost command lines.
// None of these procedures make OS calls; every length and offset is bounds-checked against the input slice.

import "core:encoding/endian"
import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf16"

// Grows an NT query buffer safely while respecting the kernel's hint and a hard cap.
next_buffer_size :: proc(current: int, needed: u32, max_bytes := MAX_NT_BUFFER_BYTES) -> (next: int, ok: bool) {
	if current < 0 || max_bytes <= 0 { return 0, false }
	cur := max(current, 4096)
	target := cur * 2
	// Add headroom over the kernel's required size because processes and handles appear between calls.
	if hint := int(needed); hint > 0 {
		headroom := hint + max(hint / 4, 16384)
		if headroom > target { target = headroom }
	}
	if target <= current { return 0, false }
	if target > max_bytes {
		if current >= max_bytes { return 0, false }
		return max_bytes, true
	}
	return target, true
}

// Converts a Windows FILETIME (100ns ticks since 1601-01-01 UTC) to Unix seconds (0 if before epoch).
filetime_to_unix_sec :: proc(ft: i64) -> i64 {
	if ft <= FILETIME_UNIX_EPOCH_TICKS { return 0 }
	return (ft - FILETIME_UNIX_EPOCH_TICKS) / FILETIME_TICKS_PER_SEC
}

// Converts Windows 100ns time ticks to nanoseconds, clamping negative kernel values to 0.
ticks_to_ns :: proc(ticks: i64) -> u64 {
	if ticks <= 0 { return 0 }
	return u64(ticks) * 100
}

// Decodes a UTF-16LE byte slice (cutting at any NUL) into UTF-8.
decode_utf16le :: proc(raw: []u8, allocator := context.temp_allocator) -> string {
	n := len(raw) / 2
	if n == 0 { return "" }
	units := make([]u16, n, context.temp_allocator)
	end := n
	for i in 0 ..< n {
		u := endian.unchecked_get_u16le(raw[i * 2:])
		if u == 0 { end = i; break }
		units[i] = u
	}
	if end == 0 { return "" }
	buf := make([]u8, end * 3 + 4, context.temp_allocator)
	written := utf16.decode_to_utf8(buf, units[:end])
	return strings.clone(string(buf[:written]), allocator)
}

// The text of a UNICODE_STRING at the start of `buf` whose characters are in `buf` too (`base`: the address of buf[0]);
// "" when they are not.
decode_unicode_string :: proc(buf: []u8, base: u64, allocator := context.temp_allocator) -> string {
	us: UNICODE_STRING64
	if len(buf) < size_of(us) { return "" }
	mem.copy(&us, raw_data(buf), size_of(us))
	if us.Length == 0 || us.Buffer < base { return "" }
	rel := us.Buffer - base
	if rel > u64(len(buf)) || rel + u64(us.Length) > u64(len(buf)) { return "" }
	return decode_utf16le(buf[int(rel):int(rel) + int(us.Length)], allocator)
}

// Decodes a UTF-16LE environment block (entries separated by NUL, ended by double NUL).
decode_utf16le_env_block :: proc(raw: []u8, out: ^[dynamic]string, allocator := context.allocator) {
	n := len(raw) / 2
	if n == 0 { return }
	units := make([]u16, n, context.temp_allocator)
	for i in 0 ..< n { units[i] = endian.unchecked_get_u16le(raw[i * 2:]) }
	start := 0
	for i := 0; i < n; i += 1 {
		if units[i] != 0 { continue }
		if i == start { break } // Double NUL terminates the environment block.
		seg := units[start:i]
		buf := make([]u8, len(seg) * 3 + 4, context.temp_allocator)
		w := utf16.decode_to_utf8(buf, seg)
		if w > 0 { append(out, strings.clone(string(buf[:w]), allocator)) }
		start = i + 1
	}
	// Handle a truncated block whose final entry lacked its trailing NUL.
	if start < n && units[start] != 0 {
		seg := units[start:n]
		buf := make([]u8, len(seg) * 3 + 4, context.temp_allocator)
		w := utf16.decode_to_utf8(buf, seg)
		if w > 0 { append(out, strings.clone(string(buf[:w]), allocator)) }
	}
}

// Decodes a NUL-separated UTF-16LE multi-string (REG_MULTI_SZ / SCM lpDependencies).
decode_utf16le_multi_sz :: proc(raw: []u8, out: ^[dynamic]string, allocator := context.allocator) {
	decode_utf16le_env_block(raw, out, allocator)
}

////////////////////////////////
// SystemProcessInformation

Decoded_Thread :: struct {
	tid:              i32,
	cpu_ns:           u64,
	create_time:      u64,
	start_address:    u64,
	priority:         i32,
	base_priority:    i32,
	context_switches: u32,
	thread_state:     u32,
	wait_reason:      u32,
}

Decoded_Process :: struct {
	pid, ppid:        i32,
	create_time:      u64,
	name:             string,
	cpu_ns:           u64,
	threads:          i32,
	base_priority:    i32,
	handles:          u32,
	session_id:       u32,
	page_faults:      u32,
	working_set:      u64,
	private_ws:       u64,
	commit:           u64,
	peak_working_set: u64,
	paged_pool:       u64,
	nonpaged_pool:    u64,
	io_read:          u64,
	io_write:         u64,
	all_suspended:    bool,
	any_running:      bool,
	thread_slice:     []Decoded_Thread,
}

// Decodes a SystemProcessInformation buffer.
// `buffer_base` is the virtual address of `buf[0]` when `ImageName.Buffer` holds live pointers
// (0 in synthetic buffers where `ImageName.Buffer` is an offset from `buf[0]`).
decode_system_processes :: proc(
	buf: []u8,
	buffer_base: u64,
	out: ^[dynamic]Decoded_Process,
	want_threads := false,
	allocator := context.temp_allocator,
) -> (ok: bool) {
	if len(buf) < size_of(SYSTEM_PROCESS_INFORMATION64) { return false }
	off := 0
	// Hard upper bound on entries prevents infinite loops on malformed NextEntryOffset chains.
	max_entries := max(len(buf) / size_of(SYSTEM_PROCESS_INFORMATION64) + 1, 1)
	for entry_idx := 0; entry_idx < max_entries; entry_idx += 1 {
		if off < 0 || off + size_of(SYSTEM_PROCESS_INFORMATION64) > len(buf) { break }
		raw: SYSTEM_PROCESS_INFORMATION64
		mem.copy(&raw, &buf[off], size_of(SYSTEM_PROCESS_INFORMATION64))

		// Resolve ImageName safely only if it points inside `buf`.
		name := ""
		img_len := int(raw.ImageName.Length)
		if img_len > 0 && (img_len & 1) == 0 && raw.ImageName.Buffer >= buffer_base {
			rel := raw.ImageName.Buffer - buffer_base
			if rel < u64(len(buf)) && int(rel) + img_len <= len(buf) {
				name = decode_utf16le(buf[int(rel):int(rel) + img_len], allocator)
			}
		}

		// Bound the thread array to both the remainder of this entry and the buffer.
		entry_end := len(buf)
		if raw.NextEntryOffset != 0 {
			next_off := u64(off) + u64(raw.NextEntryOffset)
			if next_off <= u64(off) || next_off > u64(len(buf)) { return false }
			entry_end = int(next_off)
		}
		threads_start := off + size_of(SYSTEM_PROCESS_INFORMATION64)
		avail_threads := max(0, (entry_end - threads_start) / size_of(SYSTEM_THREAD_INFORMATION64))
		tcount := min(int(raw.NumberOfThreads), avail_threads)

		all_susp := tcount > 0
		any_run := false
		threads_out: []Decoded_Thread
		if want_threads && tcount > 0 {
			threads_out = make([]Decoded_Thread, tcount, allocator)
		}
		for ti in 0 ..< tcount {
			toff := threads_start + ti * size_of(SYSTEM_THREAD_INFORMATION64)
			th: SYSTEM_THREAD_INFORMATION64
			mem.copy(&th, &buf[toff], size_of(SYSTEM_THREAD_INFORMATION64))
			// KTHREAD_STATE: 2 = Running, 5 = Waiting; KWAIT_REASON: 5 = Suspended.
			if th.ThreadState == 2 { any_run = true }
			if !(th.ThreadState == 5 && th.WaitReason == 5) { all_susp = false }
			if want_threads {
				threads_out[ti] = {
					tid              = i32(th.ClientId.UniqueThread),
					cpu_ns           = ticks_to_ns(th.KernelTime) + ticks_to_ns(th.UserTime),
					create_time      = u64(max(th.CreateTime, 0)),
					start_address    = th.StartAddress,
					priority         = th.Priority,
					base_priority    = th.BasePriority,
					context_switches = th.ContextSwitches,
					thread_state     = th.ThreadState,
					wait_reason      = th.WaitReason,
				}
			}
		}

		// (0 is true of a process whose working set was emptied, a suspended app's: the commit is another number)
		priv := u64(max(raw.WorkingSetPrivateSize, 0))
		commit := raw.PagefileUsage > 0 ? raw.PagefileUsage : raw.PrivatePageCount
		append(out, Decoded_Process{
			pid              = i32(raw.UniqueProcessId),
			ppid             = i32(raw.InheritedFromUniqueProcessId),
			create_time      = u64(max(raw.CreateTime, 0)),
			name             = name,
			cpu_ns           = ticks_to_ns(raw.KernelTime) + ticks_to_ns(raw.UserTime),
			threads          = i32(raw.NumberOfThreads),
			base_priority    = raw.BasePriority,
			handles          = raw.HandleCount,
			session_id       = raw.SessionId,
			page_faults      = raw.PageFaultCount,
			working_set      = raw.WorkingSetSize,
			private_ws       = priv,
			commit           = commit,
			peak_working_set = raw.PeakWorkingSetSize,
			paged_pool       = raw.QuotaPagedPoolUsage,
			nonpaged_pool    = raw.QuotaNonPagedPoolUsage,
			io_read          = u64(max(raw.ReadTransferCount, 0)),
			io_write         = u64(max(raw.WriteTransferCount, 0)),
			all_suspended    = all_susp,
			any_running      = any_run,
			thread_slice     = threads_out,
		})

		if raw.NextEntryOffset == 0 { return true }
		off = entry_end
	}
	return true
}

// A process's parent by its pid, unless that pid is another process's now: Windows keeps the pid of a parent that ended,
// and gives it again. A parent starts before its child (0: none).
true_parent :: proc(ppid: i32, child_create: u64, created: map[i32]u64) -> i32 {
	parent_create, ok := created[ppid]
	if !ok || parent_create > child_create { return 0 }
	return ppid
}

////////////////////////////////
// GetSystemCpuSetInformation

Decoded_Cpu_Set :: struct {
	id:    u32,
	index: int,   // the logical processor, the groups one after the other
}

// `group_sizes`: how many logical processors each group has.
decode_cpu_sets :: proc(buf: []u8, group_sizes: []int, out: ^[dynamic]Decoded_Cpu_Set) {
	off := 0
	for off + size_of(SYSTEM_CPU_SET_INFORMATION) <= len(buf) {
		e: SYSTEM_CPU_SET_INFORMATION
		mem.copy(&e, &buf[off], size_of(e))
		if e.Size < size_of(e) { return }
		if e.Type == 0 && int(e.Group) < len(group_sizes) {
			index := int(e.LogicalProcessorIndex)
			for n in group_sizes[:e.Group] { index += n }
			append(out, Decoded_Cpu_Set{e.Id, index})
		}
		off += int(e.Size)
	}
}

////////////////////////////////
// SystemProcessorPerformanceInformation

Decoded_Cpu_Time :: struct {
	total_ns: u64,
	idle_ns:  u64,
}

// Decodes an array of SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION entries.
// Windows KernelTime includes IdleTime, so total CPU time is KernelTime + UserTime.
decode_processor_performance :: proc(buf: []u8, out: ^[dynamic]Decoded_Cpu_Time) {
	n := len(buf) / size_of(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION)
	for i in 0 ..< n {
		raw: SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION
		mem.copy(&raw, &buf[i * size_of(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION)], size_of(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION))
		idle := ticks_to_ns(raw.IdleTime)
		kern := ticks_to_ns(raw.KernelTime)
		user := ticks_to_ns(raw.UserTime)
		// Guard against rare skew where KernelTime is reported slightly below IdleTime.
		total := max(kern, idle) + user
		append(out, Decoded_Cpu_Time{total_ns = total, idle_ns = idle})
	}
}

////////////////////////////////
// SystemExtendedHandleInformation

Decoded_Handle :: struct {
	pid:        i32,
	handle:     u64,
	access:     u32,
	type_index: u16,
	attributes: u32,
}

// Decodes SystemExtendedHandleInformation filtered to `pid` (0 keeps all).
decode_extended_handles :: proc(buf: []u8, pid: i32, out: ^[dynamic]Decoded_Handle, max_out := 65536) -> bool {
	if len(buf) < size_of(SYSTEM_HANDLE_INFORMATION_EX64_HEADER) { return false }
	hdr: SYSTEM_HANDLE_INFORMATION_EX64_HEADER
	mem.copy(&hdr, &buf[0], size_of(SYSTEM_HANDLE_INFORMATION_EX64_HEADER))
	avail := u64((len(buf) - size_of(SYSTEM_HANDLE_INFORMATION_EX64_HEADER)) / size_of(SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64))
	count := int(min(hdr.NumberOfHandles, avail))
	base := size_of(SYSTEM_HANDLE_INFORMATION_EX64_HEADER)
	for i in 0 ..< count {
		if len(out) >= max_out { break }
		e: SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64
		mem.copy(&e, &buf[base + i * size_of(SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64)], size_of(SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64))
		if pid != 0 && i32(e.UniqueProcessId) != pid { continue }
		append(out, Decoded_Handle{
			pid        = i32(e.UniqueProcessId),
			handle     = e.HandleValue,
			access     = e.GrantedAccess,
			type_index = e.ObjectTypeIndex,
			attributes = e.HandleAttributes,
		})
	}
	return true
}

// Granted access masks of File handles known to block NtQueryObject(ObjectNameInformation) on synchronous named pipes.
// Others may block too: the query has its own thread and a bound.
handle_name_may_hang :: proc(access: u32) -> bool {
	switch access {
	case 0x0012019f, 0x001a019f, 0x00120189, 0x00100000:
		return true
	}
	return false
}

////////////////////////////////
// PEB64 and PEB32 (WOW64)

Decoded_Peb_Params :: struct {
	cwd_addr:     u64,
	cwd_len:      u16,
	image_addr:   u64,
	image_len:    u16,
	cmdline_addr: u64,
	cmdline_len:  u16,
	env_addr:     u64,
	env_size:     u64,
}

decode_peb_params_64 :: proc(buf: []u8) -> (out: Decoded_Peb_Params, ok: bool) {
	if len(buf) < size_of(RTL_USER_PROCESS_PARAMETERS64) { return }
	p: RTL_USER_PROCESS_PARAMETERS64
	mem.copy(&p, &buf[0], size_of(RTL_USER_PROCESS_PARAMETERS64))
	return {
		cwd_addr     = p.CurrentDirectoryPath.Buffer,
		cwd_len      = p.CurrentDirectoryPath.Length,
		image_addr   = p.ImagePathName.Buffer,
		image_len    = p.ImagePathName.Length,
		cmdline_addr = p.CommandLine.Buffer,
		cmdline_len  = p.CommandLine.Length,
		env_addr     = p.Environment,
		env_size     = p.EnvironmentSize,
	}, true
}

decode_peb_params_32 :: proc(buf: []u8) -> (out: Decoded_Peb_Params, ok: bool) {
	if len(buf) < size_of(RTL_USER_PROCESS_PARAMETERS32) { return }
	p: RTL_USER_PROCESS_PARAMETERS32
	mem.copy(&p, &buf[0], size_of(RTL_USER_PROCESS_PARAMETERS32))
	return {
		cwd_addr     = u64(p.CurrentDirectoryPath.Buffer),
		cwd_len      = p.CurrentDirectoryPath.Length,
		image_addr   = u64(p.ImagePathName.Buffer),
		image_len    = p.ImagePathName.Length,
		cmdline_addr = u64(p.CommandLine.Buffer),
		cmdline_len  = p.CommandLine.Length,
		env_addr     = u64(p.Environment),
		env_size     = u64(p.EnvironmentSize),
	}, true
}

////////////////////////////////
// TCP and UDP extended tables

Decoded_Socket :: struct {
	udp:          bool,
	v6:           bool,
	local:        [16]u8,
	remote:       [16]u8,
	lport, rport: u16,
	mib_state:    u32,
	pid:          i32,
}

// Network-byte-order port stored in the low 16 bits of a Windows DWORD.
win_port :: proc(dw_port: u32) -> u16 {
	b0 := u16(dw_port & 0xFF)
	b1 := u16((dw_port >> 8) & 0xFF)
	return (b0 << 8) | b1
}

ipv4_from_u32 :: proc(addr: u32) -> (out: [16]u8) {
	out[0] = u8(addr & 0xFF)
	out[1] = u8((addr >> 8) & 0xFF)
	out[2] = u8((addr >> 16) & 0xFF)
	out[3] = u8((addr >> 24) & 0xFF)
	return
}

decode_tcp4_table :: proc(buf: []u8, out: ^[dynamic]Decoded_Socket) -> bool {
	if len(buf) < 4 { return false }
	count := int(endian.unchecked_get_u32le(buf[0:4]))
	avail := (len(buf) - 4) / size_of(MIB_TCPROW_OWNER_PID)
	n := min(count, avail)
	for i in 0 ..< n {
		r: MIB_TCPROW_OWNER_PID
		mem.copy(&r, &buf[4 + i * size_of(MIB_TCPROW_OWNER_PID)], size_of(MIB_TCPROW_OWNER_PID))
		append(out, Decoded_Socket{
			local     = ipv4_from_u32(r.dwLocalAddr),
			remote    = ipv4_from_u32(r.dwRemoteAddr),
			lport     = win_port(r.dwLocalPort),
			rport     = r.dwState == 2 ? 0 : win_port(r.dwRemotePort), // MIB_TCP_STATE_LISTEN = 2
			mib_state = r.dwState,
			pid       = i32(r.dwOwningPid),
		})
	}
	return true
}

decode_tcp6_table :: proc(buf: []u8, out: ^[dynamic]Decoded_Socket) -> bool {
	if len(buf) < 4 { return false }
	count := int(endian.unchecked_get_u32le(buf[0:4]))
	avail := (len(buf) - 4) / size_of(MIB_TCP6ROW_OWNER_PID)
	n := min(count, avail)
	for i in 0 ..< n {
		r: MIB_TCP6ROW_OWNER_PID
		mem.copy(&r, &buf[4 + i * size_of(MIB_TCP6ROW_OWNER_PID)], size_of(MIB_TCP6ROW_OWNER_PID))
		append(out, Decoded_Socket{
			v6        = true,
			local     = r.ucLocalAddr,
			remote    = r.ucRemoteAddr,
			lport     = win_port(r.dwLocalPort),
			rport     = r.dwState == 2 ? 0 : win_port(r.dwRemotePort),
			mib_state = r.dwState,
			pid       = i32(r.dwOwningPid),
		})
	}
	return true
}

decode_udp4_table :: proc(buf: []u8, out: ^[dynamic]Decoded_Socket) -> bool {
	if len(buf) < 4 { return false }
	count := int(endian.unchecked_get_u32le(buf[0:4]))
	avail := (len(buf) - 4) / size_of(MIB_UDPROW_OWNER_PID)
	n := min(count, avail)
	for i in 0 ..< n {
		r: MIB_UDPROW_OWNER_PID
		mem.copy(&r, &buf[4 + i * size_of(MIB_UDPROW_OWNER_PID)], size_of(MIB_UDPROW_OWNER_PID))
		append(out, Decoded_Socket{
			udp   = true,
			local = ipv4_from_u32(r.dwLocalAddr),
			lport = win_port(r.dwLocalPort),
			pid   = i32(r.dwOwningPid),
		})
	}
	return true
}

decode_udp6_table :: proc(buf: []u8, out: ^[dynamic]Decoded_Socket) -> bool {
	if len(buf) < 4 { return false }
	count := int(endian.unchecked_get_u32le(buf[0:4]))
	avail := (len(buf) - 4) / size_of(MIB_UDP6ROW_OWNER_PID)
	n := min(count, avail)
	for i in 0 ..< n {
		r: MIB_UDP6ROW_OWNER_PID
		mem.copy(&r, &buf[4 + i * size_of(MIB_UDP6ROW_OWNER_PID)], size_of(MIB_UDP6ROW_OWNER_PID))
		append(out, Decoded_Socket{
			udp   = true,
			v6    = true,
			local = r.ucLocalAddr,
			lport = win_port(r.dwLocalPort),
			pid   = i32(r.dwOwningPid),
		})
	}
	return true
}

////////////////////////////////
// StartupApproved (Windows Task Manager registry binary state)

// Windows Task Manager stores a 12-byte REG_BINARY value per item under Explorer\StartupApproved\*:
// - bytes[0..4]: state flags; bit 0 == 0 (0x02, 0x06, 0x00) means enabled, bit 0 == 1 (0x03, 0x07, 0x01) means disabled.
// - bytes[4..12]: FILETIME when the item was disabled (0 when enabled).
decode_startup_approved :: proc(raw: []u8) -> (enabled: bool, disabled_unix: i64, valid: bool) {
	if len(raw) < 12 { return true, 0, false }
	// Task Manager checks the low bit of byte 0 (even = enabled, odd = disabled).
	if (raw[0] & 1) != 0 {
		ft := i64(endian.unchecked_get_u64le(raw[4:12]))
		return false, filetime_to_unix_sec(ft), true
	}
	return true, 0, true
}

// Encodes the 12-byte StartupApproved value matching Windows Task Manager's format.
encode_startup_approved :: proc(enabled: bool, filetime_now: i64) -> (out: [12]u8) {
	if enabled {
		out[0] = 0x02
		return
	}
	out[0] = 0x03
	endian.unchecked_put_u64le(out[4:12], u64(max(filetime_now, 0)))
	return
}

////////////////////////////////
// Storage device descriptor

Decoded_Storage_Device :: struct {
	vendor:    string,
	product:   string,
	bus_type:  u32,
	removable: bool,
}

decode_storage_device_descriptor :: proc(buf: []u8, allocator := context.temp_allocator) -> (out: Decoded_Storage_Device, ok: bool) {
	if len(buf) < size_of(STORAGE_DEVICE_DESCRIPTOR_HEADER) { return }
	h: STORAGE_DEVICE_DESCRIPTOR_HEADER
	mem.copy(&h, &buf[0], size_of(STORAGE_DEVICE_DESCRIPTOR_HEADER))
	cstr_at :: proc(buf: []u8, off: u32, allocator: mem.Allocator) -> string {
		if off == 0 || int(off) >= len(buf) { return "" }
		end := int(off)
		for end < len(buf) && buf[end] != 0 { end += 1 }
		return strings.clone(strings.trim_space(string(buf[int(off):end])), allocator)
	}
	return {
		vendor    = cstr_at(buf, h.VendorIdOffset, allocator),
		product   = cstr_at(buf, h.ProductIdOffset, allocator),
		bus_type  = h.BusType,
		removable = h.RemovableMedia != 0,
	}, true
}

// Classifies a physical disk from bus type, removability, and seek penalty.
disk_kind_from_properties :: proc(bus_type: u32, removable: bool, has_seek_penalty: bool, incurs_seek_penalty: bool) -> string {
	if removable || bus_type == BUS_TYPE_USB || bus_type == BUS_TYPE_SD || bus_type == BUS_TYPE_MMC { return "Removable" }
	if bus_type == BUS_TYPE_NVME { return "NVMe SSD" }
	if has_seek_penalty { return incurs_seek_penalty ? "HDD" : "SSD" }
	return "Disk"
}

////////////////////////////////
// SMBIOS (GetSystemFirmwareTable 'RSMB')

Decoded_Smbios :: struct {
	bios_vendor:     string,
	bios_version:    string,
	bios_date:       string,
	sys_vendor:      string,
	sys_product:     string,
	board_vendor:    string,
	board_product:   string,
}

// Decodes a RawSMBIOSData buffer (Types 0, 1, and 2).
decode_smbios :: proc(raw: []u8, allocator := context.temp_allocator) -> (out: Decoded_Smbios, ok: bool) {
	if len(raw) < size_of(SMBIOS_RAW_HEADER) { return }
	hdr: SMBIOS_RAW_HEADER
	mem.copy(&hdr, &raw[0], size_of(SMBIOS_RAW_HEADER))
	table_end := min(len(raw), size_of(SMBIOS_RAW_HEADER) + int(hdr.Length))
	table := raw[size_of(SMBIOS_RAW_HEADER):table_end]

	str_at :: proc(strings_area: []u8, index: u8, allocator: mem.Allocator) -> string {
		if index == 0 { return "" }
		cur := u8(1)
		start := 0
		for i := 0; i < len(strings_area); i += 1 {
			if strings_area[i] != 0 { continue }
			if i == start { break } // Double NUL ends the string section.
			if cur == index { return strings.clone(strings.trim_space(string(strings_area[start:i])), allocator) }
			cur += 1
			start = i + 1
		}
		return ""
	}

	pos := 0
	for pos + 4 <= len(table) {
		stype := table[pos]
		slen := int(table[pos + 1])
		if slen < 4 || pos + slen > len(table) { break }
		// Find the double-NUL terminator after the formatted section.
		str_start := pos + slen
		str_end := str_start
		for str_end + 1 < len(table) {
			if table[str_end] == 0 && table[str_end + 1] == 0 {
				str_end += 2
				break
			}
			str_end += 1
		}
		if str_end == str_start || str_end > len(table) { break }
		sarea := table[str_start:str_end]

		switch stype {
		case 0: // BIOS Information
			if slen >= 9 {
				if out.bios_vendor == "" { out.bios_vendor = str_at(sarea, table[pos + 4], allocator) }
				if out.bios_version == "" { out.bios_version = str_at(sarea, table[pos + 5], allocator) }
				if out.bios_date == "" { out.bios_date = str_at(sarea, table[pos + 8], allocator) }
			}
		case 1: // System Information
			if slen >= 6 {
				if out.sys_vendor == "" { out.sys_vendor = str_at(sarea, table[pos + 4], allocator) }
				if out.sys_product == "" { out.sys_product = str_at(sarea, table[pos + 5], allocator) }
			}
		case 2: // Baseboard Information
			if slen >= 6 {
				if out.board_vendor == "" { out.board_vendor = str_at(sarea, table[pos + 4], allocator) }
				if out.board_product == "" { out.board_product = str_at(sarea, table[pos + 5], allocator) }
			}
		case 127: // End-of-table
			return out, true
		}
		pos = str_end
	}
	return out, true
}

////////////////////////////////
// EDID (display monitor name)

// Extracts the ASCII display product name (descriptor tag 0xFC) from a 128+ byte EDID block.
decode_edid_name :: proc(edid: []u8, allocator := context.temp_allocator) -> string {
	if len(edid) < 128 { return "" }
	// Verify standard 8-byte EDID header.
	header := [8]u8{0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00}
	if mem.compare(edid[:8], header[:]) != 0 { return "" }
	for i := 0; i < 4; i += 1 {
		d := edid[54 + i * 18:][:18]
		if d[0] == 0 && d[1] == 0 && d[2] == 0 && d[3] == 0xFC {
			raw := d[5:18]
			end := len(raw)
			for b, k in raw {
				if b == '\n' || b == '\r' || b == 0 { end = k; break }
			}
			return strings.clone(strings.trim_space(string(raw[:end])), allocator)
		}
	}
	return ""
}

////////////////////////////////
// Protection, Integrity, Priority helpers

// Formats PS_PROTECTION into a concise Windows security label ("PPL (Antimalware)", "PP (WinTcb)", "").
decode_protection_level :: proc(level: u8) -> (label: string, protected: bool) {
	ptype := level & 0x07
	signer := (level >> 4) & 0x0F
	if ptype == 0 { return "", false }
	prefix := ptype == 1 ? "PPL" : "PP"
	who: string
	switch signer {
	case 1: who = "Authenticode"
	case 2: who = "CodeGen"
	case 3: who = "Antimalware"
	case 4: who = "LSA"
	case 5: who = "Windows"
	case 6: who = "WinTcb"
	case 7: who = "WinSystem"
	case 8: who = "App"
	case:   who = "Unknown"
	}
	return fmt.tprintf("%s (%s)", prefix, who), true
}

Integrity_Level :: enum u8 {
	Unknown,
	Untrusted,
	Low,
	Medium,
	Medium_Plus,
	High,
	System,
	Protected,
}

decode_integrity_rid :: proc(rid: u32) -> Integrity_Level {
	switch {
	case rid >= SECURITY_MANDATORY_PROTECTED_PROCESS_RID: return .Protected
	case rid >= SECURITY_MANDATORY_SYSTEM_RID:            return .System
	case rid >= SECURITY_MANDATORY_HIGH_RID:              return .High
	case rid >= SECURITY_MANDATORY_MEDIUM_PLUS_RID:       return .Medium_Plus
	case rid >= SECURITY_MANDATORY_MEDIUM_RID:            return .Medium
	case rid >= SECURITY_MANDATORY_LOW_RID:               return .Low
	case:                                                 return .Untrusted
	}
}

// Maps Windows priority class to Inspecteur's neutral nice scale (-20..19).
priority_class_to_nice :: proc(class: u32) -> i8 {
	switch class {
	case REALTIME_PRIORITY_CLASS:     return -20
	case HIGH_PRIORITY_CLASS:         return -10
	case ABOVE_NORMAL_PRIORITY_CLASS: return -5
	case NORMAL_PRIORITY_CLASS:       return 0
	case BELOW_NORMAL_PRIORITY_CLASS: return 5
	case IDLE_PRIORITY_CLASS:         return 19
	}
	return 0
}

// Maps Inspecteur's nice scale back to a Windows priority class (refusing Realtime).
nice_to_priority_class :: proc(nice: i8) -> u32 {
	switch {
	case nice <= -10: return HIGH_PRIORITY_CLASS
	case nice <= -5:  return ABOVE_NORMAL_PRIORITY_CLASS
	case nice <= 0:   return NORMAL_PRIORITY_CLASS
	case nice <= 5:   return BELOW_NORMAL_PRIORITY_CLASS
	case:             return IDLE_PRIORITY_CLASS
	}
}

// Estimates nice from NT BasePriority (used during single-call SystemProcessInformation without OpenProcess).
base_priority_to_nice :: proc(base: i32) -> i8 {
	switch {
	case base >= 24: return -20
	case base >= 13: return -10
	case base >= 10: return -5
	case base >= 7:  return 0
	case base >= 6:  return 5
	case base > 0:   return 19
	}
	return 0
}

////////////////////////////////
// svchost -k group, PDH GPU instances, Task XML, Shell Link (.lnk)

// Extracts the service host group from a command line like `C:\Windows\system32\svchost.exe -k netsvcs -p -s LanmanWorkstation`.
parse_svchost_group :: proc(cmdline: string) -> string {
	s := cmdline
	for {
		idx := strings.index(s, "-k ")
		if idx < 0 { idx = strings.index(s, "-K ") }
		if idx < 0 { idx = strings.index(s, "/k ") }
		if idx < 0 { return "" }
		if idx > 0 && s[idx - 1] != ' ' && s[idx - 1] != '\t' {
			s = s[idx + 3:]
			continue
		}
		rest := strings.trim_left(s[idx + 3:], " \t")
		if rest == "" { return "" }
		if rest[0] == '"' {
			rest = rest[1:]
			if end := strings.index_byte(rest, '"'); end >= 0 { return rest[:end] }
			return rest
		}
		end := len(rest)
		for i in 0 ..< len(rest) {
			if rest[i] == ' ' || rest[i] == '\t' { end = i; break }
		}
		return rest[:end]
	}
}

Pdh_Gpu_Instance :: struct {
	pid:        i32,
	luid_high:  i32,
	luid_low:   u32,
	engine_idx: int,
	engine:     string,
}

// Parses a PDH GPU Engine or GPU Process Memory instance string:
// "pid_1234_luid_0x00000000_0x00012345_phys_0_eng_0_engtype_3D"
// or "pid_1234_luid_0x00000000_0x00012345_phys_0".
parse_pdh_gpu_instance :: proc(inst: string) -> (out: Pdh_Gpu_Instance, ok: bool) {
	if !strings.has_prefix(inst, "pid_") { return }
	rest := inst[4:]
	sep := strings.index_byte(rest, '_')
	if sep <= 0 { return }
	pid_v, pok := strconv.parse_int(rest[:sep], 10)
	if !pok || pid_v <= 0 { return }
	out.pid = i32(pid_v)

	luid_pos := strings.index(rest[sep:], "_luid_")
	if luid_pos < 0 { return }
	luid_rest := rest[sep + luid_pos + 6:]
	// Expect two hex numbers: 0xHHHHHHHH_0xLLLLLLLL
	u1 := strings.index_byte(luid_rest, '_')
	if u1 <= 0 { return }
	hi_str := strings.trim_prefix(strings.trim_prefix(luid_rest[:u1], "0x"), "0X")
	hi_u, hok := strconv.parse_u64(hi_str, 16)
	if !hok { return }
	out.luid_high = i32(u32(hi_u))

	low_part := luid_rest[u1 + 1:]
	u2 := strings.index_byte(low_part, '_')
	if u2 < 0 { u2 = len(low_part) }
	lo_str := strings.trim_prefix(strings.trim_prefix(low_part[:u2], "0x"), "0X")
	lo_u, lok := strconv.parse_u64(lo_str, 16)
	if !lok { return }
	out.luid_low = u32(lo_u)

	if et := strings.index(low_part, "_engtype_"); et >= 0 {
		out.engine = low_part[et + 9:]
	}
	if ei := strings.index(low_part, "_eng_"); ei >= 0 {
		er := low_part[ei + 5:]
		ee := strings.index_byte(er, '_')
		if ee < 0 { ee = len(er) }
		if ev, eok := strconv.parse_int(er[:ee], 10); eok { out.engine_idx = ev }
	}
	return out, true
}

// Parses a PDH GPU Adapter Memory instance string ("luid_0x00000000_0x00012345_phys_0").
parse_pdh_adapter_luid :: proc(inst: string) -> (high: i32, low: u32, ok: bool) {
	pos := strings.index(inst, "luid_")
	if pos < 0 { return }
	rest := inst[pos + 5:]
	u1 := strings.index_byte(rest, '_')
	if u1 <= 0 { return }
	hi_str := strings.trim_prefix(strings.trim_prefix(rest[:u1], "0x"), "0X")
	hi_u, hok := strconv.parse_u64(hi_str, 16)
	if !hok { return }
	low_part := rest[u1 + 1:]
	u2 := strings.index_byte(low_part, '_')
	if u2 < 0 { u2 = len(low_part) }
	lo_str := strings.trim_prefix(strings.trim_prefix(low_part[:u2], "0x"), "0X")
	lo_u, lok := strconv.parse_u64(lo_str, 16)
	if !lok { return }
	return i32(u32(hi_u)), u32(lo_u), true
}

Decoded_If_Counter :: struct {
	alias: string,
	rx:    u64,
	tx:    u64,
}

// Decodes a MIB_IF_TABLE2 buffer (skipping loopback interfaces).
decode_if_table2 :: proc(buf: []u8, out: ^[dynamic]Decoded_If_Counter, allocator := context.temp_allocator) -> bool {
	if len(buf) < size_of(MIB_IF_TABLE2_HEADER) { return false }
	hdr: MIB_IF_TABLE2_HEADER
	mem.copy(&hdr, &buf[0], size_of(MIB_IF_TABLE2_HEADER))
	avail := (len(buf) - size_of(MIB_IF_TABLE2_HEADER)) / size_of(MIB_IF_ROW2)
	n := min(int(hdr.NumEntries), avail)
	base := size_of(MIB_IF_TABLE2_HEADER)
	for i in 0 ..< n {
		row: MIB_IF_ROW2
		mem.copy(&row, &buf[base + i * size_of(MIB_IF_ROW2)], size_of(MIB_IF_ROW2))
		// Skip software loopback (IF_TYPE_SOFTWARE_LOOPBACK = 24) and the filter drivers stacked on an interface (bit 1,
		// FilterInterface): each repeats the bytes of the interface under it.
		if row.Type == 24 || row.InterfaceAndOperStatusFlags & 0x02 != 0 { continue }
		alias_bytes := mem.slice_to_bytes(row.Alias[:])
		alias := decode_utf16le(alias_bytes, allocator)
		if alias == "" { continue }
		append(out, Decoded_If_Counter{
			alias = alias,
			rx    = row.InOctets,
			tx    = row.OutOctets,
		})
	}
	return true
}

Decoded_Task_Xml :: struct {
	has_logon_trigger: bool,
	enabled:           bool,
	command:           string,
	arguments:         string,
	user_id:           string,
}

// Parses a Windows Task Scheduler XML file (UTF-16LE with BOM or UTF-8) for LogonTrigger Exec tasks.
parse_task_xml :: proc(raw: []u8, allocator := context.temp_allocator) -> (out: Decoded_Task_Xml, ok: bool) {
	if len(raw) < 16 { return }
	text: string
	// Task Scheduler writes UTF-16LE XML files with BOM (FF FE) on Windows.
	if len(raw) >= 2 && raw[0] == 0xFF && raw[1] == 0xFE {
		text = decode_utf16le(raw[2:], context.temp_allocator)
	} else if len(raw) >= 4 && raw[1] == 0 && raw[3] == 0 {
		text = decode_utf16le(raw, context.temp_allocator)
	} else if len(raw) >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF {
		text = string(raw[3:])
	} else {
		text = string(raw)
	}
	if !strings.contains(text, "<Task") { return }
	out.has_logon_trigger = strings.contains(text, "<LogonTrigger")
	if !out.has_logon_trigger { return out, true }

	// Settings/<Enabled> defaults to true in the Task Scheduler XML schema unless explicitly false.
	out.enabled = true
	if settings := xml_tag_inner(text, "Settings"); settings != "" {
		if en := xml_tag_inner(settings, "Enabled"); strings.equal_fold(strings.trim_space(en), "false") {
			out.enabled = false
		}
	}
	if trig := xml_tag_inner(text, "LogonTrigger"); trig != "" {
		if en := xml_tag_inner(trig, "Enabled"); strings.equal_fold(strings.trim_space(en), "false") {
			out.enabled = false
		}
		out.user_id = strings.clone(strings.trim_space(xml_tag_inner(trig, "UserId")), allocator)
	}
	if exec := xml_tag_inner(text, "Exec"); exec != "" {
		out.command = xml_unescape(strings.trim_space(xml_tag_inner(exec, "Command")), allocator)
		out.arguments = xml_unescape(strings.trim_space(xml_tag_inner(exec, "Arguments")), allocator)
	}
	return out, true
}

@(private = "file")
xml_tag_inner :: proc(doc, tag: string) -> string {
	open_a := strings.concatenate({"<", tag, ">"}, context.temp_allocator)
	open_b := strings.concatenate({"<", tag, " "}, context.temp_allocator)
	close := strings.concatenate({"</", tag, ">"}, context.temp_allocator)
	start := strings.index(doc, open_a)
	body_start := 0
	if start >= 0 {
		body_start = start + len(open_a)
	} else if sb := strings.index(doc, open_b); sb >= 0 {
		gt := strings.index_byte(doc[sb:], '>')
		if gt < 0 { return "" }
		// Self-closing tag has no body.
		if doc[sb + gt - 1] == '/' { return "" }
		body_start = sb + gt + 1
	} else {
		return ""
	}
	end := strings.index(doc[body_start:], close)
	if end < 0 { return "" }
	return doc[body_start:body_start + end]
}

// A text as it is in an element's content.
xml_escape :: proc(s: string, allocator := context.temp_allocator) -> string {
	r := s
	r, _ = strings.replace_all(r, "&", "&amp;", context.temp_allocator)
	r, _ = strings.replace_all(r, "<", "&lt;", context.temp_allocator)
	r, _ = strings.replace_all(r, ">", "&gt;", context.temp_allocator)
	return strings.clone(r, allocator)
}

// The year, month, day, hour, minute and second of an event's SystemTime ("2026-11-25T08:01:12.1234567Z").
parse_event_time :: proc(s: string) -> (t: [6]int, ok: bool) {
	if len(s) < 19 || s[4] != '-' || s[7] != '-' || s[10] != 'T' || s[13] != ':' || s[16] != ':' { return }
	parts := [6]string{s[0:4], s[5:7], s[8:10], s[11:13], s[14:16], s[17:19]}
	for p, i in parts { t[i] = strconv.parse_int(p, 10) or_return }
	return t, true
}

@(private = "file")
xml_unescape :: proc(s: string, allocator: mem.Allocator) -> string {
	if strings.index_byte(s, '&') < 0 { return strings.clone(s, allocator) }
	r := s
	r, _ = strings.replace_all(r, "&quot;", "\"", context.temp_allocator)
	r, _ = strings.replace_all(r, "&apos;", "'", context.temp_allocator)
	r, _ = strings.replace_all(r, "&lt;", "<", context.temp_allocator)
	r, _ = strings.replace_all(r, "&gt;", ">", context.temp_allocator)
	r, _ = strings.replace_all(r, "&amp;", "&", context.temp_allocator)
	return strings.clone(r, allocator)
}

////////////////////////////////
// Shell Link (.lnk) binary format ([MS-SHLLINK])

Decoded_Lnk :: struct {
	target:    string,
	arguments: string,
	icon:      string,
}

// The bytes of the system's code page, read as Latin-1 (temporary): the paths of western systems whole, never bytes that
// are not UTF-8.
@(private = "file")
latin1_to_utf8 :: proc(b: []u8) -> string {
	out := strings.builder_make(0, len(b) + 8, context.temp_allocator)
	for c in b { strings.write_rune(&out, rune(c)) }
	return strings.to_string(out)
}

// The executable of a command line or of a service's image path: `"C:\Program Files\App\a.exe" -k x`,
// `C:\Program Files\App\a.exe -k x` (no quotes: up to its .exe, .com, .sys, .dll, .bat or .cmd), and the kernel's own
// forms of a driver's path (`\SystemRoot\System32\...`, `System32\drivers\...`, `\??\C:\...`), as %SystemRoot% paths.
exe_of_command :: proc(cmd: string, allocator := context.temp_allocator) -> string {
	s := strings.trim_space(cmd)
	if s == "" { return "" }
	if s[0] == '"' {
		s = s[1:]
		if end := strings.index_byte(s, '"'); end >= 0 { s = s[:end] }
	} else {
		low := strings.to_lower(s, context.temp_allocator)
		cut := -1
		if len(low) == len(s) {
			for ext in ([]string{".exe", ".com", ".sys", ".dll", ".bat", ".cmd"}) {
				from := 0
				for {
					at := strings.index(low[from:], ext)
					if at < 0 { break }
					end := from + at + len(ext)
					if end == len(s) || s[end] == ' ' || s[end] == '\t' {
						if cut < 0 || end < cut { cut = end }
						break
					}
					from = end
				}
			}
		}
		if cut < 0 { cut = strings.index_byte(s, ' ') }
		if cut >= 0 { s = s[:cut] }
	}
	s = strings.trim_prefix(s, "\\??\\")
	low := strings.to_lower(s, context.temp_allocator)
	switch {
	case strings.has_prefix(low, "\\systemroot\\"): return strings.concatenate({"%SystemRoot%", s[len("\\systemroot"):]}, allocator)
	case strings.has_prefix(low, "system32\\"):      return strings.concatenate({"%SystemRoot%\\", s}, allocator)
	}
	return strings.clone(s, allocator)
}

// Parses a Windows Shell Link (.lnk) binary file without COM initialization.
// Extracts local target path (LinkInfo), relative path fallback, arguments, and icon location.
decode_lnk :: proc(raw: []u8, allocator := context.temp_allocator) -> (out: Decoded_Lnk, ok: bool) {
	// ShellLinkHeader is fixed 76 bytes (0x4C) with CLSID 00021401-0000-0000-C000-000000000046.
	if len(raw) < 76 { return }
	if endian.unchecked_get_u32le(raw[0:4]) != 0x0000004C { return }
	clsid := [16]u8{0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}
	if mem.compare(raw[4:20], clsid[:]) != 0 { return }

	flags := endian.unchecked_get_u32le(raw[20:24])
	has_id_list  := (flags & 0x0001) != 0
	has_linkinfo := (flags & 0x0002) != 0
	has_name     := (flags & 0x0004) != 0
	has_relpath  := (flags & 0x0008) != 0
	has_workdir  := (flags & 0x0010) != 0
	has_args     := (flags & 0x0020) != 0
	has_icon     := (flags & 0x0040) != 0
	is_unicode   := (flags & 0x0080) != 0

	pos := 76
	if has_id_list {
		if pos + 2 > len(raw) { return out, true }
		id_size := int(endian.unchecked_get_u16le(raw[pos:pos + 2]))
		pos += 2 + id_size
		if pos > len(raw) { return out, true }
	}

	if has_linkinfo {
		if pos + 4 > len(raw) { return out, true }
		li_size := int(endian.unchecked_get_u32le(raw[pos:pos + 4]))
		if li_size < 28 || pos + li_size > len(raw) { return out, true }
		li := raw[pos:pos + li_size]
		li_hdr_size := int(endian.unchecked_get_u32le(li[4:8]))
		li_flags := endian.unchecked_get_u32le(li[8:12])
		if (li_flags & 0x01) != 0 { // VolumeIDAndLocalBasePath
			base_path := ""
			suffix := ""
			if li_hdr_size >= 36 && len(li) >= 36 {
				u_base := int(endian.unchecked_get_u32le(li[28:32]))
				u_suf := int(endian.unchecked_get_u32le(li[32:36]))
				if u_base > 0 && u_base < len(li) { base_path = decode_utf16le(li[u_base:], context.temp_allocator) }
				if u_suf > 0 && u_suf < len(li) { suffix = decode_utf16le(li[u_suf:], context.temp_allocator) }
			}
			if base_path == "" {
				a_base := int(endian.unchecked_get_u32le(li[16:20]))
				a_suf := int(endian.unchecked_get_u32le(li[24:28]))
				if a_base > 0 && a_base < len(li) {
					end := a_base
					for end < len(li) && li[end] != 0 { end += 1 }
					base_path = latin1_to_utf8(li[a_base:end])
				}
				if a_suf > 0 && a_suf < len(li) {
					end := a_suf
					for end < len(li) && li[end] != 0 { end += 1 }
					suffix = latin1_to_utf8(li[a_suf:end])
				}
			}
			if base_path != "" {
				out.target = suffix != "" ? strings.concatenate({base_path, suffix}, allocator) : strings.clone(base_path, allocator)
			}
		}
		pos += li_size
	}

	read_counted_str :: proc(raw: []u8, pos: ^int, unicode: bool, allocator: mem.Allocator) -> string {
		if pos^ + 2 > len(raw) { pos^ = len(raw); return "" }
		chars := int(endian.unchecked_get_u16le(raw[pos^:pos^ + 2]))
		pos^ += 2
		bytes := unicode ? chars * 2 : chars
		if bytes < 0 || pos^ + bytes > len(raw) { pos^ = len(raw); return "" }
		seg := raw[pos^:pos^ + bytes]
		pos^ += bytes
		if unicode { return decode_utf16le(seg, allocator) }
		return strings.clone(latin1_to_utf8(seg), allocator)
	}

	if has_name { _ = read_counted_str(raw, &pos, is_unicode, context.temp_allocator) }
	if has_relpath {
		rel := read_counted_str(raw, &pos, is_unicode, context.temp_allocator)
		if out.target == "" && rel != "" { out.target = strings.clone(rel, allocator) }
	}
	if has_workdir { _ = read_counted_str(raw, &pos, is_unicode, context.temp_allocator) }
	if has_args { out.arguments = read_counted_str(raw, &pos, is_unicode, allocator) }
	if has_icon { out.icon = read_counted_str(raw, &pos, is_unicode, allocator) }

	// Scan ExtraData blocks for EnvironmentVariableDataBlock (signature 0xA0000001) if target is still empty.
	for pos + 8 <= len(raw) {
		bsize := int(endian.unchecked_get_u32le(raw[pos:pos + 4]))
		if bsize < 8 || pos + bsize > len(raw) { break }
		bsig := endian.unchecked_get_u32le(raw[pos + 4:pos + 8])
		if bsig == 0xA0000001 && out.target == "" && bsize >= 788 {
			// Unicode target is at offset 268 (after 8-byte header + 260-byte ANSI target).
			u := decode_utf16le(raw[pos + 268:pos + 788], allocator)
			if u != "" { out.target = u }
		}
		pos += bsize
	}
	return out, true
}
