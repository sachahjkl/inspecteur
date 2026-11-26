package winapi

import "core:encoding/endian"
import "core:mem"
import "core:strings"
import "core:testing"

// Encodes ASCII text as UTF-16LE bytes (with optional trailing NUL).
@(private = "file")
utf16le_bytes :: proc(s: string, nul := true, allocator := context.temp_allocator) -> []u8 {
	extra := nul ? 1 : 0
	out := make([]u8, (len(s) + extra) * 2, allocator)
	for i in 0 ..< len(s) {
		endian.unchecked_put_u16le(out[i * 2:], u16(s[i]))
	}
	return out
}

// The allocator of a test (the runner's Rollback_Stack) gives a slice of bytes at any address: the reads of the processes
// failed now and then, after an allocation of an odd size. aligned_bytes never does.
@(test)
a_buffer_for_the_kernel_is_aligned_whatever_the_allocator :: proc(t: ^testing.T) {
	stack: mem.Rollback_Stack
	if !testing.expect(t, mem.rollback_stack_init(&stack, 1 << 20) == nil) { return }
	defer mem.rollback_stack_destroy(&stack)
	a := mem.rollback_stack_allocator(&stack)
	misaligned := 0
	for odd in 1 ..< 16 {
		_, _ = make([]u8, odd, a)
		plain := make([]u8, 4096, a)
		if uintptr(raw_data(plain)) % 4 != 0 { misaligned += 1 }
		b := aligned_bytes(256 * 1024, a)
		testing.expectf(t, len(b) == 256 * 1024 && uintptr(raw_data(b)) % 16 == 0, "after %d bytes: %p", odd, raw_data(b))
	}
	// (the cause: without its alignment, a byte slice lands where the last allocation ended)
	testing.expectf(t, misaligned > 0, "a plain slice of bytes was always aligned (%d times misaligned)", misaligned)
}

@(test)
buffer_growth_is_bounded_and_adds_headroom :: proc(t: ^testing.T) {
	n, ok := next_buffer_size(64 * 1024, 0)
	testing.expect(t, ok && n == 128 * 1024)

	n, ok = next_buffer_size(64 * 1024, 200 * 1024)
	testing.expect(t, ok && n > 200 * 1024)

	// Cap at MAX_NT_BUFFER_BYTES, then fail instead of looping forever.
	n, ok = next_buffer_size(MAX_NT_BUFFER_BYTES - 1024, max(u32))
	testing.expect(t, ok && n == MAX_NT_BUFFER_BYTES)
	_, ok = next_buffer_size(MAX_NT_BUFFER_BYTES, max(u32))
	testing.expect(t, !ok)
}

@(test)
system_processes_decode_valid_chain_and_threads :: proc(t: ^testing.T) {
	// Two processes: first has 2 threads (1 running, 1 waiting) + UTF-16 name; second has 1 suspended thread.
	name1 := utf16le_bytes("notepad.exe", nul = false)
	name2 := utf16le_bytes("worker.exe", nul = false)

	e1_size := size_of(SYSTEM_PROCESS_INFORMATION64) + 2 * size_of(SYSTEM_THREAD_INFORMATION64) + len(name1)
	e1_aligned := (e1_size + 7) & ~int(7)
	e2_size := size_of(SYSTEM_PROCESS_INFORMATION64) + 1 * size_of(SYSTEM_THREAD_INFORMATION64) + len(name2)
	buf := make([]u8, e1_aligned + e2_size, context.temp_allocator)

	base_addr := u64(0x0000_7FF0_1000_0000)

	p1_name_off := size_of(SYSTEM_PROCESS_INFORMATION64) + 2 * size_of(SYSTEM_THREAD_INFORMATION64)
	copy(buf[p1_name_off:], name1)
	p1 := SYSTEM_PROCESS_INFORMATION64{
		NextEntryOffset              = u32(e1_aligned),
		NumberOfThreads              = 2,
		WorkingSetPrivateSize        = 12 * 1024 * 1024,
		CreateTime                   = FILETIME_UNIX_EPOCH_TICKS + 1_700_000_000 * FILETIME_TICKS_PER_SEC,
		UserTime                     = 5_000_000,   // 0.5 s
		KernelTime                   = 2_500_000,   // 0.25 s
		ImageName                    = {Length = u16(len(name1)), MaximumLength = u16(len(name1)), Buffer = base_addr + u64(p1_name_off)},
		BasePriority                 = 8,
		UniqueProcessId              = 4200,
		InheritedFromUniqueProcessId = 1000,
		HandleCount                  = 312,
		SessionId                    = 1,
		WorkingSetSize               = 20 * 1024 * 1024,
		PagefileUsage                = 18 * 1024 * 1024,
		ReadTransferCount            = 8192,
		WriteTransferCount           = 4096,
	}
	mem.copy(&buf[0], &p1, size_of(p1))
	t1a := SYSTEM_THREAD_INFORMATION64{KernelTime = 1_000_000, UserTime = 2_000_000, ClientId = {4200, 4201}, ThreadState = 2, WaitReason = 0}
	t1b := SYSTEM_THREAD_INFORMATION64{KernelTime = 1_500_000, UserTime = 3_000_000, ClientId = {4200, 4202}, ThreadState = 5, WaitReason = 6}
	mem.copy(&buf[size_of(p1)], &t1a, size_of(t1a))
	mem.copy(&buf[size_of(p1) + size_of(t1a)], &t1b, size_of(t1b))

	p2_name_off := e1_aligned + size_of(SYSTEM_PROCESS_INFORMATION64) + size_of(SYSTEM_THREAD_INFORMATION64)
	copy(buf[p2_name_off:], name2)
	p2 := SYSTEM_PROCESS_INFORMATION64{
		NextEntryOffset              = 0,
		NumberOfThreads              = 1,
		WorkingSetPrivateSize        = 0,
		PrivatePageCount             = 4 * 1024 * 1024,
		ImageName                    = {Length = u16(len(name2)), MaximumLength = u16(len(name2)), Buffer = base_addr + u64(p2_name_off)},
		BasePriority                 = 4,
		UniqueProcessId              = 4300,
		InheritedFromUniqueProcessId = 4200,
	}
	mem.copy(&buf[e1_aligned], &p2, size_of(p2))
	t2 := SYSTEM_THREAD_INFORMATION64{ClientId = {4300, 4301}, ThreadState = 5, WaitReason = 5} // Suspended
	mem.copy(&buf[e1_aligned + size_of(p2)], &t2, size_of(t2))

	out := make([dynamic]Decoded_Process, context.temp_allocator)
	ok := decode_system_processes(buf, base_addr, &out, want_threads = true)
	testing.expect(t, ok)
	if !testing.expect_value(t, len(out), 2) { return }

	testing.expect_value(t, out[0].pid, i32(4200))
	testing.expect_value(t, out[0].ppid, i32(1000))
	testing.expect_value(t, out[0].name, "notepad.exe")
	testing.expect_value(t, out[0].cpu_ns, u64(750_000_000))
	testing.expect_value(t, out[0].private_ws, u64(12 * 1024 * 1024))
	testing.expect_value(t, out[0].commit, u64(18 * 1024 * 1024))
	testing.expect_value(t, out[0].handles, u32(312))
	testing.expect_value(t, out[0].session_id, u32(1))
	testing.expect(t, out[0].any_running && !out[0].all_suspended)
	testing.expect_value(t, len(out[0].thread_slice), 2)
	testing.expect_value(t, out[0].thread_slice[1].tid, i32(4202))
	testing.expect_value(t, out[0].first_tid, i32(4201))
	testing.expect_value(t, filetime_to_unix_sec(i64(out[0].create_time)), i64(1_700_000_000))

	testing.expect_value(t, out[1].pid, i32(4300))
	testing.expect_value(t, out[1].name, "worker.exe")
	testing.expect_value(t, out[1].private_ws, u64(0))   // (an emptied working set: not the commit)
	testing.expect_value(t, out[1].commit, u64(4 * 1024 * 1024))
	testing.expect(t, out[1].all_suspended && !out[1].any_running)
}

@(test)
system_processes_reject_truncated_and_hostile_buffers :: proc(t: ^testing.T) {
	out := make([dynamic]Decoded_Process, context.temp_allocator)

	// Truncated buffer shorter than one header.
	testing.expect(t, !decode_system_processes(make([]u8, 100, context.temp_allocator), 0, &out))
	testing.expect_value(t, len(out), 0)

	// Hostile NextEntryOffset beyond buffer end and bogus huge NumberOfThreads + out-of-bounds ImageName pointer.
	hostile := make([]u8, 512, context.temp_allocator)
	p := SYSTEM_PROCESS_INFORMATION64{
		NextEntryOffset = 999999,
		NumberOfThreads = 1_000_000,
		ImageName       = {Length = 60000, MaximumLength = 60000, Buffer = 0xDEAD_BEEF},
		UniqueProcessId = 77,
	}
	mem.copy(&hostile[0], &p, size_of(p))
	testing.expect(t, !decode_system_processes(hostile, 0, &out, want_threads = true))

	// Valid NextEntryOffset = 0, but huge NumberOfThreads must clamp safely without OOM or panic.
	clear(&out)
	p.NextEntryOffset = 0
	mem.copy(&hostile[0], &p, size_of(p))
	testing.expect(t, decode_system_processes(hostile, 0, &out, want_threads = true))
	testing.expect_value(t, len(out), 1)
	testing.expect_value(t, out[0].name, "")
	testing.expect(t, len(out[0].thread_slice) <= (512 - size_of(p)) / size_of(SYSTEM_THREAD_INFORMATION64))
}

@(test)
processor_performance_counts_kernel_including_idle :: proc(t: ^testing.T) {
	testing.expect_value(t, processor_performance_length(16 * 1024), 341 * 48)   // (16384 is refused)
	testing.expect_value(t, processor_performance_length(64 * 48), 64 * 48)
	testing.expect_value(t, processor_performance_length(47), 0)
	items := [2]SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION{
		{IdleTime = 4_000_000, KernelTime = 6_000_000, UserTime = 4_000_000}, // total = 10M ticks, idle = 4M (60% busy)
		{IdleTime = 9_000_000, KernelTime = 8_500_000, UserTime = 1_000_000}, // skewed kernel < idle clamped safely
	}
	raw := mem.slice_to_bytes(items[:])
	out := make([dynamic]Decoded_Cpu_Time, context.temp_allocator)
	decode_processor_performance(raw, &out)
	if !testing.expect_value(t, len(out), 2) { return }
	testing.expect_value(t, out[0].total_ns, u64(1_000_000_000))
	testing.expect_value(t, out[0].idle_ns, u64(400_000_000))
	testing.expect(t, out[1].total_ns >= out[1].idle_ns)
}

@(test)
extended_handles_filter_and_guard_hostile_count :: proc(t: ^testing.T) {
	hdr := SYSTEM_HANDLE_INFORMATION_EX64_HEADER{NumberOfHandles = max(u64)} // hostile count
	e1 := SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64{UniqueProcessId = 100, HandleValue = 0x40, GrantedAccess = 0x0012019f, ObjectTypeIndex = 37}
	e2 := SYSTEM_EXTENDED_HANDLE_TABLE_ENTRY_INFO64{UniqueProcessId = 200, HandleValue = 0x44, GrantedAccess = 0x001F0003, ObjectTypeIndex = 7}
	buf := make([]u8, size_of(hdr) + 2 * size_of(e1), context.temp_allocator)
	mem.copy(&buf[0], &hdr, size_of(hdr))
	mem.copy(&buf[size_of(hdr)], &e1, size_of(e1))
	mem.copy(&buf[size_of(hdr) + size_of(e1)], &e2, size_of(e2))

	out := make([dynamic]Decoded_Handle, context.temp_allocator)
	testing.expect(t, decode_extended_handles(buf, 100, &out))
	if !testing.expect_value(t, len(out), 1) { return }
	testing.expect_value(t, out[0].handle, u64(0x40))
	testing.expect(t, handle_name_may_hang(out[0].access))
	testing.expect(t, !handle_name_may_hang(e2.GrantedAccess))
}

@(test)
peb64_peb32_and_utf16_env_block_decode :: proc(t: ^testing.T) {
	p64 := RTL_USER_PROCESS_PARAMETERS64{
		CurrentDirectoryPath = {Length = 20, Buffer = 0x1111_2222_3333_4444},
		CommandLine          = {Length = 44, Buffer = 0x5555_6666_7777_8888},
		Environment          = 0x9999_0000_AAAA_BBBB,
		EnvironmentSize      = 4096,
	}
	d64, ok64 := decode_peb_params_64(mem.ptr_to_bytes(&p64))
	testing.expect(t, ok64 && d64.cwd_addr == 0x1111_2222_3333_4444 && d64.env_addr == 0x9999_0000_AAAA_BBBB && d64.env_size == 4096)

	p32 := RTL_USER_PROCESS_PARAMETERS32{
		CurrentDirectoryPath = {Length = 16, Buffer = 0x0040_1000},
		CommandLine          = {Length = 30, Buffer = 0x0040_2000},
		Environment          = 0x0050_0000,
		EnvironmentSize      = 2048,
	}
	d32, ok32 := decode_peb_params_32(mem.ptr_to_bytes(&p32))
	testing.expect(t, ok32 && d32.cwd_addr == 0x0040_1000 && d32.env_addr == 0x0050_0000 && d32.env_size == 2048)

	// Truncated PEB buffers fail cleanly.
	_, bad64 := decode_peb_params_64(make([]u8, 64, context.temp_allocator))
	_, bad32 := decode_peb_params_32(make([]u8, 64, context.temp_allocator))
	testing.expect(t, !bad64 && !bad32)

	// UTF-16LE env block with Windows drive-current-dir entry (`=C:=C:\Windows`) and trailing double NUL.
	b := make([dynamic]u8, context.temp_allocator)
	append(&b, ..utf16le_bytes("=C:=C:\\Windows", nul = true))
	append(&b, ..utf16le_bytes("PATH=C:\\Windows\\System32", nul = true))
	append(&b, 0, 0) // double NUL
	append(&b, ..utf16le_bytes("IGNORED=1", nul = true))

	env := make([dynamic]string, context.temp_allocator)
	decode_utf16le_env_block(b[:], &env, context.temp_allocator)
	if !testing.expect_value(t, len(env), 2) { return }
	testing.expect_value(t, env[0], "=C:=C:\\Windows")
	testing.expect_value(t, env[1], "PATH=C:\\Windows\\System32")
}

@(test)
tcp_and_udp_tables_decode_v4_and_v6 :: proc(t: ^testing.T) {
	// TCPv4: 1 listening socket on 127.0.0.1:8080 (port in network byte order: 0x1F90 -> bytes 0x1F, 0x90 -> u32le 0x0000901F).
	row4 := MIB_TCPROW_OWNER_PID{
		dwState      = 2, // LISTEN
		dwLocalAddr  = 0x0100007F,
		dwLocalPort  = 0x0000901F,
		dwRemoteAddr = 0,
		dwRemotePort = 0x0000FFFF, // Windows puts garbage in remote port for LISTEN; decoder must zero it.
		dwOwningPid  = 1234,
	}
	t4 := make([]u8, 4 + size_of(row4), context.temp_allocator)
	endian.unchecked_put_u32le(t4[0:4], 999) // hostile oversized dwNumEntries must clamp to available rows
	mem.copy(&t4[4], &row4, size_of(row4))
	out := make([dynamic]Decoded_Socket, context.temp_allocator)
	testing.expect(t, decode_tcp4_table(t4, &out))
	if !testing.expect_value(t, len(out), 1) { return }
	testing.expect_value(t, out[0].lport, u16(8080))
	testing.expect_value(t, out[0].rport, u16(0))
	testing.expect_value(t, out[0].local[0], u8(127))
	testing.expect_value(t, out[0].local[3], u8(1))
	testing.expect_value(t, out[0].pid, i32(1234))

	// TCPv6 established on [::1]:443.
	row6 := MIB_TCP6ROW_OWNER_PID{
		ucLocalAddr  = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		dwLocalPort  = 0x0000BB01, // 443 = 0x01BB
		ucRemoteAddr = {0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2},
		dwRemotePort = 0x00005000, // 80 = 0x0050
		dwState      = 5, // ESTAB
		dwOwningPid  = 5678,
	}
	t6 := make([]u8, 4 + size_of(row6), context.temp_allocator)
	endian.unchecked_put_u32le(t6[0:4], 1)
	mem.copy(&t6[4], &row6, size_of(row6))
	clear(&out)
	testing.expect(t, decode_tcp6_table(t6, &out))
	if !testing.expect_value(t, len(out), 1) { return }
	testing.expect(t, out[0].v6 && out[0].lport == 443 && out[0].rport == 80 && out[0].pid == 5678)

	// UDPv4 and UDPv6.
	u4 := MIB_UDPROW_OWNER_PID{dwLocalAddr = 0, dwLocalPort = 0x00003500, dwOwningPid = 999} // port 53
	ub4 := make([]u8, 4 + size_of(u4), context.temp_allocator)
	endian.unchecked_put_u32le(ub4[0:4], 1)
	mem.copy(&ub4[4], &u4, size_of(u4))
	clear(&out)
	testing.expect(t, decode_udp4_table(ub4, &out))
	testing.expect(t, len(out) == 1 && out[0].udp && out[0].lport == 53 && out[0].pid == 999)
}

@(test)
startup_approved_matches_task_manager_bits :: proc(t: ^testing.T) {
	// Short buffer is invalid (defaults to enabled).
	en, _, valid := decode_startup_approved([]u8{0x03, 0x00})
	testing.expect(t, en && !valid)

	// Task Manager enabled values (0x02, 0x06).
	for b in ([2]u8{0x02, 0x06}) {
		raw := [12]u8{b, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
		e, _, v := decode_startup_approved(raw[:])
		testing.expect(t, e && v)
	}

	// Round-trip disabled with timestamp.
	ft := FILETIME_UNIX_EPOCH_TICKS + 1_750_000_000 * FILETIME_TICKS_PER_SEC
	enc := encode_startup_approved(false, ft)
	e, ts, v := decode_startup_approved(enc[:])
	testing.expect(t, !e && v && ts == 1_750_000_000)

	enc_on := encode_startup_approved(true, ft)
	e2, ts2, v2 := decode_startup_approved(enc_on[:])
	testing.expect(t, e2 && v2 && ts2 == 0)
}

@(test)
smbios_and_edid_and_storage_decode :: proc(t: ^testing.T) {
	// Synthetic SMBIOS with Type 0 (BIOS), Type 1 (System), Type 2 (Baseboard), Type 127 (End).
	sm := make([dynamic]u8, context.temp_allocator)
	append(&sm, 0, 3, 2, 0, 0, 0, 0, 0) // header placeholder
	body_start := len(sm)
	// Type 0: length 9, vendor=1, version=2, date=3
	append(&sm, 0, 9, 0, 0, 1, 2, 0, 0, 3)
	append(&sm, ..transmute([]u8)string("AMI\x00F12\x0010/01/2025\x00\x00"))
	// Type 1: length 8, manufacturer=1, product=2
	append(&sm, 1, 8, 1, 0, 1, 2, 0, 0)
	append(&sm, ..transmute([]u8)string("Acme Corp\x00Workstation X1\x00\x00"))
	// Type 2: length 8, manufacturer=1, product=2
	append(&sm, 2, 8, 2, 0, 1, 2, 0, 0)
	append(&sm, ..transmute([]u8)string("Acme Board\x00B650 Pro\x00\x00"))
	// Type 127: end
	append(&sm, 127, 4, 3, 0, 0, 0)
	endian.unchecked_put_u32le(sm[4:8], u32(len(sm) - body_start))

	s, sok := decode_smbios(sm[:])
	testing.expect(t, sok)
	testing.expect_value(t, s.bios_vendor, "AMI")
	testing.expect_value(t, s.bios_version, "F12")
	testing.expect_value(t, s.sys_vendor, "Acme Corp")
	testing.expect_value(t, s.sys_product, "Workstation X1")
	testing.expect_value(t, s.board_product, "B650 Pro")

	// Synthetic EDID with 0xFC descriptor.
	edid: [128]u8
	copy(edid[:8], []u8{0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00})
	edid[54 + 3] = 0xFC
	copy(edid[54 + 5:], transmute([]u8)string("DELL U2723QE\n"))
	testing.expect_value(t, decode_edid_name(edid[:]), "DELL U2723QE")

	// Storage descriptor.
	sbuf := make([]u8, 64, context.temp_allocator)
	sh := STORAGE_DEVICE_DESCRIPTOR_HEADER{Version = 36, Size = 64, VendorIdOffset = 36, ProductIdOffset = 44, BusType = BUS_TYPE_NVME}
	mem.copy(&sbuf[0], &sh, size_of(sh))
	copy(sbuf[36:], transmute([]u8)string("Samsung\x00"))
	copy(sbuf[44:], transmute([]u8)string("990 PRO 2TB\x00"))
	sd, sdok := decode_storage_device_descriptor(sbuf)
	testing.expect(t, sdok && sd.vendor == "Samsung" && sd.product == "990 PRO 2TB" && disk_kind_from_properties(sd.bus_type, sd.removable, false, false) == "NVMe SSD")
}

// A pid that Windows gave again is not a parent: End process tree would end a process that is of no tree.
@(test)
a_parent_that_started_after_its_child_is_none :: proc(t: ^testing.T) {
	created := make(map[i32]u64, 4, context.temp_allocator)
	created[10], created[20] = 100, 900
	testing.expect_value(t, true_parent(10, 500, created), i32(10))
	testing.expect_value(t, true_parent(10, 100, created), i32(10))
	testing.expect_value(t, true_parent(20, 500, created), i32(0))   // (20 was given again after)
	testing.expect_value(t, true_parent(30, 500, created), i32(0))   // (ended)
}

@(test)
a_process_is_suspended_when_each_thread_is :: proc(t: ^testing.T) {
	testing.expect_value(t, suspension_of({1, 1}, true, false), Suspension.Suspended)
	testing.expect_value(t, suspension_of({2, 1}, true, true), Suspension.Suspended)
	testing.expect_value(t, suspension_of({1, 0}, true, false), Suspension.Runs)
	testing.expect_value(t, suspension_of({0, 0}, true, true), Suspension.Frozen)
	testing.expect_value(t, suspension_of({1}, false, false), Suspension.Unknown)   // (never suspended again on a guess)
	testing.expect_value(t, suspension_of({}, true, true), Suspension.Unknown)
}

@(test)
cpu_sets_are_numbered_group_after_group :: proc(t: ^testing.T) {
	e := [3]SYSTEM_CPU_SET_INFORMATION{
		{Size = 32, Id = 256, Group = 0, LogicalProcessorIndex = 3},
		{Size = 32, Id = 300, Group = 1, LogicalProcessorIndex = 2},
		{Size = 32, Id = 301, Group = 9, LogicalProcessorIndex = 0},   // (no such group)
	}
	out := make([dynamic]Decoded_Cpu_Set, context.temp_allocator)
	decode_cpu_sets(mem.slice_to_bytes(e[:]), {60, 60}, &out)
	if !testing.expect_value(t, len(out), 2) { return }
	testing.expect_value(t, out[0], Decoded_Cpu_Set{256, 3})
	testing.expect_value(t, out[1], Decoded_Cpu_Set{300, 62})
	// A size of 0 ends the walk (it would never move).
	e[0].Size = 0
	clear(&out)
	decode_cpu_sets(mem.slice_to_bytes(e[:]), {60, 60}, &out)
	testing.expect_value(t, len(out), 0)
}

@(test)
a_unicode_string_outside_its_buffer_is_empty :: proc(t: ^testing.T) {
	buf: [64]u8
	text := utf16le_bytes("File", nul = false)
	copy(buf[16:], text)
	us := UNICODE_STRING64{Length = 8, MaximumLength = 8, Buffer = 0x1010}
	mem.copy(&buf[0], &us, size_of(us))
	testing.expect_value(t, decode_unicode_string(buf[:], 0x1000), "File")
	for bad in ([]UNICODE_STRING64{{Length = 8, Buffer = 0xFFF}, {Length = 8, Buffer = 0x1000 + 60}, {Length = 8, Buffer = max(u64)}, {Length = 0, Buffer = 0x1010}}) {
		us = bad
		mem.copy(&buf[0], &us, size_of(us))
		testing.expect_value(t, decode_unicode_string(buf[:], 0x1000), "")
	}
	testing.expect_value(t, decode_unicode_string(buf[:8], 0x1000), "")
}

@(test)
the_executable_of_a_command :: proc(t: ^testing.T) {
	for c in ([][2]string{
		{`"C:\Program Files\App\a.exe" -k x`, `C:\Program Files\App\a.exe`},
		{`C:\Program Files\App\a.exe -k x`, `C:\Program Files\App\a.exe`},
		{`C:\x.exe.old\run.exe`, `C:\x.exe.old\run.exe`},
		{`\SystemRoot\System32\drivers\ntfs.sys`, `%SystemRoot%\System32\drivers\ntfs.sys`},
		{`System32\drivers\ntfs.sys`, `%SystemRoot%\System32\drivers\ntfs.sys`},
		{`\??\C:\Windows\x.sys`, `C:\Windows\x.sys`},
		{`tool --flag`, `tool`}, {`"C:\a b`, `C:\a b`}, {``, ``},
	}) { testing.expect_value(t, exe_of_command(c[0]), c[1]) }
}

@(test)
an_event_s_time :: proc(t: ^testing.T) {
	v, ok := parse_event_time("2026-11-25T08:01:12.1234567Z")
	testing.expect(t, ok && v == [6]int{2026, 11, 25, 8, 1, 12})
	for bad in ([]string{"", "2026-11-25 08:01:12", "2026-11-25T08:xx:12Z"}) {
		_, ok = parse_event_time(bad)
		testing.expect(t, !ok)
	}
}

@(test)
svchost_pdh_task_xml_and_security_helpers :: proc(t: ^testing.T) {
	testing.expect_value(t, parse_svchost_group(`C:\Windows\system32\svchost.exe -k netsvcs -p -s Schedule`), "netsvcs")
	testing.expect_value(t, parse_svchost_group(`svchost.exe -k "LocalServiceNetworkRestricted"`), "LocalServiceNetworkRestricted")
	testing.expect_value(t, parse_svchost_group(`C:\Windows\explorer.exe`), "")

	g, gok := parse_pdh_gpu_instance("pid_4321_luid_0x00000000_0x00012A3F_phys_0_eng_2_engtype_3D")
	testing.expect(t, gok && g.pid == 4321 && g.luid_low == 0x12A3F && g.engine_idx == 2 && g.engine == "3D")
	_, badg := parse_pdh_gpu_instance("_Total")
	testing.expect(t, !badg)

	ahi, alo, aok := parse_pdh_adapter_luid("luid_0x00000000_0x00010A4F_phys_0")
	testing.expect(t, aok && ahi == 0 && alo == 0x00010A4F)

	// Synthetic MIB_IF_TABLE2: loopback (Type 24) skipped, Ethernet kept, truncated fails cleanly.
	if_buf := make([]u8, size_of(MIB_IF_TABLE2_HEADER) + 3 * size_of(MIB_IF_ROW2), context.temp_allocator)
	ihdr := MIB_IF_TABLE2_HEADER{NumEntries = 3}
	mem.copy(&if_buf[0], &ihdr, size_of(ihdr))
	r0 := MIB_IF_ROW2{Type = 24, InOctets = 111, OutOctets = 222}
	r0.Alias[0] = 'L'; r0.Alias[1] = 'o'
	r1 := MIB_IF_ROW2{Type = 6, InOctets = 9876543210, OutOctets = 1234567890}
	r1.Alias[0] = 'E'; r1.Alias[1] = 't'; r1.Alias[2] = 'h'
	mem.copy(&if_buf[size_of(MIB_IF_TABLE2_HEADER)], &r0, size_of(r0))
	mem.copy(&if_buf[size_of(MIB_IF_TABLE2_HEADER) + size_of(MIB_IF_ROW2)], &r1, size_of(r1))
	r2 := r1   // (a filter driver over the same interface: its bytes are that one's)
	r2.InterfaceAndOperStatusFlags = 0x02
	mem.copy(&if_buf[size_of(MIB_IF_TABLE2_HEADER) + 2 * size_of(MIB_IF_ROW2)], &r2, size_of(r2))
	nics := make([dynamic]Decoded_If_Counter, context.temp_allocator)
	testing.expect(t, decode_if_table2(if_buf, &nics))
	testing.expect_value(t, len(nics), 1)
	testing.expect_value(t, nics[0].alias, "Eth")
	testing.expect_value(t, nics[0].rx, u64(9876543210))
	testing.expect_value(t, nics[0].tx, u64(1234567890))
	testing.expect(t, !decode_if_table2(if_buf[:4], &nics))

	xml_str := `<?xml version="1.0" encoding="UTF-16"?><Task version="1.2"><Triggers><LogonTrigger><Enabled>true</Enabled><UserId>DESKTOP\Alex</UserId></LogonTrigger></Triggers><Settings><Enabled>true</Enabled></Settings><Actions><Exec><Command>C:\Tools\sync.exe</Command><Arguments>--quiet &amp; --tray</Arguments></Exec></Actions></Task>`
	raw_xml := make([dynamic]u8, context.temp_allocator)
	append(&raw_xml, 0xFF, 0xFE)
	append(&raw_xml, ..utf16le_bytes(xml_str, nul = false))
	tx, tok := parse_task_xml(raw_xml[:])
	testing.expect(t, tok && tx.has_logon_trigger && tx.enabled && tx.command == `C:\Tools\sync.exe` && tx.arguments == "--quiet & --tray")

	// Protection and integrity.
	plabel, prot := decode_protection_level((3 << 4) | 1) // PPL Antimalware
	testing.expect(t, prot && plabel == "PPL (Antimalware)")
	_, not_prot := decode_protection_level(0)
	testing.expect(t, !not_prot)
	testing.expect_value(t, decode_integrity_rid(SECURITY_MANDATORY_HIGH_RID), Integrity_Level.High)
	testing.expect_value(t, decode_integrity_rid(SECURITY_MANDATORY_MEDIUM_RID), Integrity_Level.Medium)

	// Priority round-trip never promotes to Realtime.
	testing.expect_value(t, priority_class_to_nice(HIGH_PRIORITY_CLASS), i8(-10))
	testing.expect_value(t, nice_to_priority_class(-20), HIGH_PRIORITY_CLASS)
	testing.expect_value(t, nice_to_priority_class(19), IDLE_PRIORITY_CLASS)

	// Minimal valid .lnk with LinkInfo ANSI path + Unicode arguments.
	lnk := make([dynamic]u8, context.temp_allocator)
	resize(&lnk, 76)
	endian.unchecked_put_u32le(lnk[0:4], 0x4C)
	copy(lnk[4:20], []u8{0x01, 0x14, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46})
	endian.unchecked_put_u32le(lnk[20:24], 0x0002 | 0x0020 | 0x0080) // HasLinkInfo | HasArguments | IsUnicode
	target_str := "C:\\Program Files\\App\\app.exe\x00"
	li_size := 28 + len(target_str) + 1
	li := make([]u8, li_size, context.temp_allocator)
	endian.unchecked_put_u32le(li[0:4], u32(li_size))
	endian.unchecked_put_u32le(li[4:8], 28)
	endian.unchecked_put_u32le(li[8:12], 1) // VolumeIDAndLocalBasePath
	endian.unchecked_put_u32le(li[16:20], 28)
	endian.unchecked_put_u32le(li[24:28], u32(28 + len(target_str)))
	copy(li[28:], transmute([]u8)target_str)
	append(&lnk, ..li)
	args_u16 := utf16le_bytes("--minimized", nul = false)
	arg_hdr: [2]u8
	endian.unchecked_put_u16le(arg_hdr[:], u16(len("--minimized")))
	append(&lnk, ..arg_hdr[:])
	append(&lnk, ..args_u16)
	dl, dlok := decode_lnk(lnk[:])
	testing.expect(t, dlok && dl.target == `C:\Program Files\App\app.exe` && dl.arguments == "--minimized")
	// The ANSI path of a shortcut is UTF-8 here, whatever its letters.
	for &c in lnk { if c == 'P' { c = 0xE9 } }
	dl, dlok = decode_lnk(lnk[:])
	testing.expect(t, dlok && strings.has_prefix(dl.target, `C:\é`))
}
