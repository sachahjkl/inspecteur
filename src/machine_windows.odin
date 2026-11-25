package inspecteur

// Windows machine counters, CPU topology/frequency, physical disks, and network adapters:
// - CPU: each logical processor across processor groups (>64 CPUs), and their sum:
//   NtQuerySystemInformationEx / NtQuerySystemInformation (SystemProcessorPerformanceInformation).
// - Memory & system handles: GlobalMemoryStatusEx + GetPerformanceInfo; page files: EnumPageFiles.
// - Topology & caches: GetLogicalProcessorInformationEx (RelationAll) + CentralProcessor\0 registry.
// - Live frequencies: CallNtPowerInformation(ProcessorInformation) from powrprof.dll.
// - Physical disks: IOCTL_STORAGE_QUERY_PROPERTY + DeviceSeekPenaltyDescriptor +
//   IOCTL_DISK_GET_DRIVE_GEOMETRY_EX + IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS + IOCTL_DISK_PERFORMANCE.
// - Network adapters & byte counters: GetAdaptersAddresses + GetIfTable2 / FreeMibTable.

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import winapi "winapi"

@(private = "file") IOCTL_DISK_PERFORMANCE            :: win.DWORD(0x00070020)
@(private = "file") IOCTL_DISK_GET_DRIVE_GEOMETRY_EX  :: win.DWORD(0x000700A0)
@(private = "file") IOCTL_STORAGE_QUERY_PROPERTY      :: win.DWORD(0x002D1400)
@(private = "file") IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS :: win.DWORD(0x00560000)

@(private = "file") IF_TYPE_ETHERNET_CSMACD     :: u32(6)
@(private = "file") IF_TYPE_SOFTWARE_LOOPBACK   :: u32(24)
@(private = "file") IF_TYPE_PPP                 :: u32(23)
@(private = "file") IF_TYPE_IEEE80211           :: u32(71)
@(private = "file") IF_TYPE_TUNNEL              :: u32(131)

@(private = "file")
Win_Mach_Procs :: struct {
	GetSystemTimes:                   proc "system" (idle, kernel, user: ^win.FILETIME) -> win.BOOL,
	GetTickCount64:                   proc "system" () -> u64,
	EnumPageFilesW:                   proc "system" (cb: proc "system" (ctx: rawptr, info: ^winapi.ENUM_PAGE_FILE_INFORMATION64, name: [^]u16) -> win.BOOL, ctx: rawptr) -> win.BOOL,
	GetLogicalProcessorInformationEx: proc "system" (rel: u32, buf: rawptr, ret_len: ^win.DWORD) -> win.BOOL,
	GetLogicalDriveStringsW:          proc "system" (buf_len: win.DWORD, buf: [^]u16) -> win.DWORD,
	CallNtPowerInformation:           proc "system" (level: u32, in_buf: rawptr, in_len: u32, out_buf: rawptr, out_len: u32) -> i32,
	GetIfTable2:                      proc "system" (table: ^rawptr) -> u32,
	FreeMibTable:                     proc "system" (mem_ptr: rawptr),
}

@(private = "file") win_mach_once: sync.Once
@(private = "file") win_mach_procs: Win_Mach_Procs

@(private = "file")
win_mach :: proc() -> ^Win_Mach_Procs {
	sync.once_do(&win_mach_once, proc() {
		if k32 := win.GetModuleHandleW(win.L("kernel32.dll")); k32 != nil {
			win_mach_procs.GetSystemTimes                   = auto_cast win.GetProcAddress(k32, "GetSystemTimes")
			win_mach_procs.GetTickCount64                   = auto_cast win.GetProcAddress(k32, "GetTickCount64")
			win_mach_procs.GetLogicalProcessorInformationEx = auto_cast win.GetProcAddress(k32, "GetLogicalProcessorInformationEx")
			win_mach_procs.GetLogicalDriveStringsW          = auto_cast win.GetProcAddress(k32, "GetLogicalDriveStringsW")
			win_mach_procs.EnumPageFilesW                   = auto_cast win.GetProcAddress(k32, "K32EnumPageFilesW")
		}
		if pp := win_system_library("powrprof.dll"); pp != nil {
			win_mach_procs.CallNtPowerInformation = auto_cast win.GetProcAddress(pp, "CallNtPowerInformation")
		}
		if ip := win_system_library("iphlpapi.dll"); ip != nil {
			win_mach_procs.GetIfTable2  = auto_cast win.GetProcAddress(ip, "GetIfTable2")
			win_mach_procs.FreeMibTable = auto_cast win.GetProcAddress(ip, "FreeMibTable")
		}
	})
	return &win_mach_procs
}

@(private = "file")
Win_Page_Files :: struct { total, used: u64 }   // pages

@(private = "file")
win_page_file_cb :: proc "system" (ctx: rawptr, info: ^winapi.ENUM_PAGE_FILE_INFORMATION64, name: [^]u16) -> win.BOOL {
	sum := (^Win_Page_Files)(ctx)
	sum.total += info.TotalSize
	sum.used += info.TotalInUse
	return true
}

Machine_Reader :: struct {
	perf_buf:    []u8,     // reused buffer for SystemProcessorPerformanceInformation
	drives:      [32]bool, // physical drives discovered in last probe
	drive_ticks: int,
}

machine_reader_init :: proc(r: ^Machine_Reader) {
	r.perf_buf = make([]u8, 16 * 1024)
}

machine_reader_destroy :: proc(r: ^Machine_Reader) {
	delete(r.perf_buf)
	r^ = {}
}

machine_read :: proc(r: ^Machine_Reader, c: ^Machine_Counters) {
	c.core_total_ns = make([dynamic]u64, 0, 16, context.temp_allocator)
	c.core_idle_ns  = make([dynamic]u64, 0, 16, context.temp_allocator)
	c.disks         = make([dynamic]Disk_Counters, 0, 8, context.temp_allocator)
	c.nets          = make([dynamic]Net_Counters, 0, 8, context.temp_allocator)
	c.has_load      = false
	c.has_pressure  = false

	m := win_mach()
	d := win_dyn()

	// The machine's total is the sum of the processors', every group's (GetSystemTimes may tell its own group alone): the
	// total and the processes' share of it are then of the same processors.
	win_read_per_core_times(r, c)
	for i in 0 ..< len(c.core_total_ns) {
		c.cpu_total_ns += c.core_total_ns[i]
		c.cpu_idle_ns  += c.core_idle_ns[i]
	}
	if c.cpu_total_ns == 0 && m.GetSystemTimes != nil {
		idle_ft, kern_ft, user_ft: win.FILETIME
		if m.GetSystemTimes(&idle_ft, &kern_ft, &user_ft) {
			idle := winapi.ticks_to_ns(i64(win_filetime_u64(idle_ft)))
			kern := winapi.ticks_to_ns(i64(win_filetime_u64(kern_ft)))   // (the idle time is in it)
			user := winapi.ticks_to_ns(i64(win_filetime_u64(user_ft)))
			c.cpu_idle_ns  = idle
			c.cpu_total_ns = max(kern, idle) + user
		}
	}

	// Boot time and uptime.
	if d.NtQuerySystemInformation != nil {
		tod: winapi.SYSTEM_TIMEOFDAY_INFORMATION
		ret: u32
		if d.NtQuerySystemInformation(WIN_NT_SYSTEM_TIMEOFDAY_INFO, &tod, size_of(tod), &ret) == winapi.STATUS_SUCCESS {
			c.boot_time = winapi.filetime_to_unix_sec(tod.BootTime)
		}
	}
	if m.GetTickCount64 != nil {
		c.uptime = f64(m.GetTickCount64()) / 1000.0
	}

	// Memory and global handle count.
	ms := win.MEMORYSTATUSEX{dwLength = size_of(win.MEMORYSTATUSEX)}
	if win.GlobalMemoryStatusEx(&ms) {
		c.mem.total        = u64(ms.ullTotalPhys)
		c.mem.available    = u64(ms.ullAvailPhys)
		c.mem.free         = u64(ms.ullAvailPhys)
		c.mem.commit_limit = u64(ms.ullTotalPageFile)
		if ms.ullTotalPageFile >= ms.ullAvailPageFile {
			c.mem.committed = u64(ms.ullTotalPageFile - ms.ullAvailPageFile)
		}
	}
	pi := win.PERFORMANCE_INFORMATION{cb = size_of(win.PERFORMANCE_INFORMATION)}
	if win.GetPerformanceInfo(&pi, size_of(pi)) {
		ps := u64(pi.PageSize)
		c.handles = u64(pi.HandleCount)
		if pi.PhysicalTotal > 0 { c.mem.total = u64(pi.PhysicalTotal) * ps }
		c.mem.available    = u64(pi.PhysicalAvailable) * ps
		c.mem.free         = c.mem.available
		c.mem.cached       = u64(pi.SystemCache) * ps
		c.mem.reclaimable  = u64(pi.KernelPaged) * ps      // Paged pool
		c.mem.buffers      = u64(pi.KernelNonpaged) * ps   // Non-paged pool
		c.mem.committed    = u64(pi.CommitTotal) * ps
		c.mem.commit_limit = u64(pi.CommitLimit) * ps
	}
	// (the page files themselves: the commit limit less the memory is not their size, nor the commit their use)
	if m.EnumPageFilesW != nil && pi.PageSize > 0 {
		sum: Win_Page_Files
		if m.EnumPageFilesW(win_page_file_cb, &sum) {
			c.mem.swap_total = sum.total * u64(pi.PageSize)
			c.mem.swap_free = (sum.total - min(sum.used, sum.total)) * u64(pi.PageSize)
		}
	}

	// Physical disk I/O counters via IOCTL_DISK_PERFORMANCE.
	if r.drive_ticks % DEVICES_EVERY == 0 {
		win_probe_physical_drives(&r.drives)
	}
	r.drive_ticks += 1
	for n in 0 ..< len(r.drives) {
		if !r.drives[n] { continue }
		if dc, ok := win_disk_perf(n); ok { append(&c.disks, dc) }
	}

	// Network interface byte counters via GetIfTable2.
	if m.GetIfTable2 != nil && m.FreeMibTable != nil {
		tbl: rawptr
		if m.GetIfTable2(&tbl) == 0 && tbl != nil {
			defer m.FreeMibTable(tbl)
			hdr := (^winapi.MIB_IF_TABLE2_HEADER)(tbl)
			// Bound decoded slice to header + reported entries.
			count := min(int(hdr.NumEntries), 4096)
			total_bytes := size_of(winapi.MIB_IF_TABLE2_HEADER) + count * size_of(winapi.MIB_IF_ROW2)
			raw := ([^]u8)(tbl)[:total_bytes]
			decoded := make([dynamic]winapi.Decoded_If_Counter, 0, count, context.temp_allocator)
			if winapi.decode_if_table2(raw, &decoded, context.temp_allocator) {
				for nic in decoded {
					append(&c.nets, Net_Counters{name = nic.alias, rx = nic.rx, tx = nic.tx})
				}
			}
		}
	}
}

@(private = "file")
win_read_per_core_times :: proc(r: ^Machine_Reader, c: ^Machine_Counters) {
	d := win_dyn()
	if d.NtQuerySystemInformation == nil { return }
	if len(r.perf_buf) < 4096 {
		delete(r.perf_buf)
		r.perf_buf = make([]u8, 16 * 1024)
	}

	groups := d.GetActiveProcessorGroupCount != nil ? int(d.GetActiveProcessorGroupCount()) : 1
	if groups > 1 && d.NtQuerySystemInformationEx != nil {
		decoded := make([dynamic]winapi.Decoded_Cpu_Time, 0, 64, context.temp_allocator)
		for g in 0 ..< groups {
			gid := u16(g)
			for _ in 0 ..< 4 {
				ret: u32
				st := d.NtQuerySystemInformationEx(WIN_NT_SYSTEM_PERF_INFO, &gid, size_of(gid), raw_data(r.perf_buf), u32(len(r.perf_buf)), &ret)
				if st == winapi.STATUS_SUCCESS {
					clear(&decoded)
					nbytes := min(int(ret), len(r.perf_buf))
					winapi.decode_processor_performance(r.perf_buf[:nbytes], &decoded)
					for ct in decoded {
						append(&c.core_total_ns, ct.total_ns)
						append(&c.core_idle_ns, ct.idle_ns)
					}
					break
				}
				if st != winapi.STATUS_INFO_LENGTH_MISMATCH { break }
				next, ok := winapi.next_buffer_size(len(r.perf_buf), ret)
				if !ok { break }
				delete(r.perf_buf)
				r.perf_buf = make([]u8, next)
			}
		}
		if len(c.core_total_ns) > 0 { return }
	}

	// Single processor group (<= 64 logical processors) or fallback.
	for _ in 0 ..< 4 {
		ret: u32
		st := d.NtQuerySystemInformation(WIN_NT_SYSTEM_PERF_INFO, raw_data(r.perf_buf), u32(len(r.perf_buf)), &ret)
		if st == winapi.STATUS_SUCCESS {
			decoded := make([dynamic]winapi.Decoded_Cpu_Time, 0, 64, context.temp_allocator)
			nbytes := min(int(ret), len(r.perf_buf))
			winapi.decode_processor_performance(r.perf_buf[:nbytes], &decoded)
			for ct in decoded {
				append(&c.core_total_ns, ct.total_ns)
				append(&c.core_idle_ns, ct.idle_ns)
			}
			return
		}
		if st != winapi.STATUS_INFO_LENGTH_MISMATCH { return }
		next, ok := winapi.next_buffer_size(len(r.perf_buf), ret)
		if !ok { return }
		delete(r.perf_buf)
		r.perf_buf = make([]u8, next)
	}
}

@(private = "file")
win_open_physical_drive :: proc(n: int) -> win.HANDLE {
	path := win.utf8_to_wstring(fmt.tprintf("\\\\.\\PhysicalDrive%d", n), context.temp_allocator)
	h := win.CreateFileW(path, 0, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, 0, nil)
	if h == win.INVALID_HANDLE_VALUE { return nil }
	return h
}

@(private = "file")
win_probe_physical_drives :: proc(drives: ^[32]bool) {
	drives^ = {}
	misses := 0
	for n in 0 ..< len(drives) {
		h := win_open_physical_drive(n)
		if h != nil {
			drives[n] = true
			win.CloseHandle(h)
			misses = 0
		} else {
			misses += 1
			if n >= 8 && misses >= 4 { break }
		}
	}
}

@(private = "file")
win_disk_perf :: proc(n: int) -> (dc: Disk_Counters, ok: bool) {
	h := win_open_physical_drive(n)
	if h == nil { return }
	defer win.CloseHandle(h)
	perf: winapi.DISK_PERFORMANCE
	got: win.DWORD
	if !win.DeviceIoControl(h, IOCTL_DISK_PERFORMANCE, nil, 0, &perf, size_of(perf), &got, nil) { return }
	if got < size_of(winapi.DISK_PERFORMANCE) { return }
	// (the time it was not idle: the reads' and the writes' times overlap, and sum to more than the time that went)
	busy_ticks := max(perf.QueryTime - perf.IdleTime, 0)
	return Disk_Counters{
		name          = fmt.tprintf("PhysicalDrive%d", n),
		read_bytes    = u64(max(perf.BytesRead, 0)),
		written_bytes = u64(max(perf.BytesWritten, 0)),
		busy_ms       = u64(busy_ticks / 10_000), // 100ns ticks -> milliseconds
	}, true
}

// Reads static CPU model, socket/core/logical counts, base MHz, and L1-L3 caches.
cpu_info_read :: proc() -> (info: Cpu_Info) {
	if model, ok := win_reg_read_string(win.HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", "ProcessorNameString"); ok {
		info.model = strings.clone(strings.trim_space(model))
	}
	if mhz, ok := win_reg_read_dword(win.HKEY_LOCAL_MACHINE, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", "~MHz"); ok {
		info.base_mhz = f32(mhz)
	}

	d := win_dyn()
	if d.GetActiveProcessorCount != nil {
		// 0xFFFF = ALL_PROCESSOR_GROUPS
		info.logical = int(d.GetActiveProcessorCount(0xFFFF))
	}

	m := win_mach()
	if m.GetLogicalProcessorInformationEx != nil {
		RelationAll :: u32(0xFFFF)
		need: win.DWORD
		_ = m.GetLogicalProcessorInformationEx(RelationAll, nil, &need)
		if need > 0 && need < 16 * 1024 * 1024 {
			buf := win_bytes(int(need))
			if m.GetLogicalProcessorInformationEx(RelationAll, raw_data(buf), &need) {
				off := 0
				limit := min(int(need), len(buf))
				for off + 8 <= limit {
					rel, sz: u32
					mem.copy(&rel, &buf[off], 4)
					mem.copy(&sz, &buf[off + 4], 4)
					if sz < 8 || off + int(sz) > limit { break }
					switch rel {
					case 0: // RelationProcessorCore
						info.cores += 1
					case 2: // RelationCache
						// CACHE_RELATIONSHIP begins at off + 8: Level(u8, +0), Assoc(u8, +1), LineSize(u16, +2), CacheSize(u32, +4).
						if sz >= 16 {
							lvl := buf[off + 8]
							csz: u32
							mem.copy(&csz, &buf[off + 12], 4)
							if lvl >= 1 && lvl <= 4 { info.cache[lvl - 1] += u64(csz) }
						}
					case 3: // RelationProcessorPackage
						info.sockets += 1
					}
					off += int(sz)
				}
			}
		}
	}
	if info.sockets == 0 && info.logical > 0 { info.sockets = 1 }
	if info.cores == 0 { info.cores = info.logical }
	return
}

// Reads current per-logical-processor frequency via CallNtPowerInformation(ProcessorInformation).
cpu_mhz_now :: proc(cores: []f32) -> f32 {
	m := win_mach()
	if m.CallNtPowerInformation == nil || len(cores) == 0 { return 0 }
	buf := make([]winapi.PROCESSOR_POWER_INFORMATION, len(cores), context.temp_allocator)
	ProcessorInformation :: u32(11)
	if m.CallNtPowerInformation(ProcessorInformation, nil, 0, raw_data(buf), u32(len(buf) * size_of(winapi.PROCESSOR_POWER_INFORMATION))) != 0 {
		return 0
	}
	sum: f32
	n := 0
	for p, i in buf {
		if i >= len(cores) { break }
		cores[i] = f32(p.CurrentMhz)
		if p.CurrentMhz > 0 { sum += f32(p.CurrentMhz); n += 1 }
	}
	return n > 0 ? sum / f32(n) : 0
}

// Lists physical disks with model, SSD/NVMe/HDD/Removable classification, capacity, and mounted drive letters.
disks_list :: proc(out: ^[dynamic]Disk_Info) {
	// Map physical disk number -> drive letters ("C:\", "D:\").
	mounts_by_disk := make(map[u32][dynamic]string, 8, context.temp_allocator)
	m := win_mach()
	if m.GetLogicalDriveStringsW != nil {
		wbuf: [512]u16
		n := m.GetLogicalDriveStringsW(len(wbuf), &wbuf[0])
		if n > 0 && int(n) < len(wbuf) {
			i := 0
			for i < int(n) && wbuf[i] != 0 {
				start := i
				for i < int(n) && wbuf[i] != 0 { i += 1 }
				drive := win_utf16_to_utf8(wbuf[start:i], context.temp_allocator)
				i += 1
				if len(drive) < 2 { continue }
				// Open volume path "\\.\C:" without trailing backslash.
				vol_path := win.utf8_to_wstring(fmt.tprintf("\\\\.\\%s", drive[:2]), context.temp_allocator)
				vh := win.CreateFileW(vol_path, 0, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, 0, nil)
				if vh == win.INVALID_HANDLE_VALUE { continue }
				ebuf: [256]u8
				got: win.DWORD
				if win.DeviceIoControl(vh, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, nil, 0, &ebuf[0], size_of(ebuf), &got, nil) &&
					got >= size_of(winapi.VOLUME_DISK_EXTENTS_HEADER) {
					hdr: winapi.VOLUME_DISK_EXTENTS_HEADER
					mem.copy(&hdr, &ebuf[0], size_of(hdr))
					avail := (int(got) - size_of(winapi.VOLUME_DISK_EXTENTS_HEADER)) / size_of(winapi.DISK_EXTENT)
					for k in 0 ..< min(int(hdr.NumberOfDiskExtents), avail) {
						ext: winapi.DISK_EXTENT
						mem.copy(&ext, &ebuf[size_of(winapi.VOLUME_DISK_EXTENTS_HEADER) + k * size_of(winapi.DISK_EXTENT)], size_of(ext))
						list := mounts_by_disk[ext.DiskNumber]
						if list.allocator.procedure == nil { list = make([dynamic]string, context.temp_allocator) }
						dup := false
						for existing in list { if existing == drive { dup = true; break } }
						if !dup { append(&list, drive) }
						mounts_by_disk[ext.DiskNumber] = list
					}
				}
				win.CloseHandle(vh)
			}
		}
	}

	StoragePropertyQuery :: struct {
		PropertyId: u32,
		QueryType:  u32,
		Additional: [1]u8,
	}

	misses := 0
	for n in 0 ..< 32 {
		h := win_open_physical_drive(n)
		if h == nil {
			misses += 1
			if n >= 8 && misses >= 4 { break }
			continue
		}
		misses = 0
		defer win.CloseHandle(h)

		// Capacity (IOCTL_DISK_GET_LENGTH_INFO wants read access to the disk, which a standard user has not).
		geometry: [64]u64   // (DISK_GEOMETRY_EX has a variable end)
		cap_bytes: i64
		got: win.DWORD
		if win.DeviceIoControl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, nil, 0, &geometry[0], size_of(geometry), &got, nil) && got >= size_of(winapi.DISK_GEOMETRY_EX_HEAD) {
			cap_bytes = (^winapi.DISK_GEOMETRY_EX_HEAD)(&geometry[0]).DiskSize
		}

		// Model, bus type, removability via StorageDeviceProperty.
		q := StoragePropertyQuery{PropertyId = 0, QueryType = 0}
		sbuf: [1024]u8
		desc: winapi.Decoded_Storage_Device
		has_desc := false
		if win.DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &q, size_of(q), &sbuf[0], size_of(sbuf), &got, nil) && got >= size_of(winapi.STORAGE_DEVICE_DESCRIPTOR_HEADER) {
			desc, has_desc = winapi.decode_storage_device_descriptor(sbuf[:int(got)], context.temp_allocator)
		}

		// Seek penalty (SSD vs HDD) via StorageDeviceSeekPenaltyProperty (7).
		sq := StoragePropertyQuery{PropertyId = 7, QueryType = 0}
		sp: winapi.DEVICE_SEEK_PENALTY_DESCRIPTOR
		has_seek := win.DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, &sq, size_of(sq), &sp, size_of(sp), &got, nil) &&
			got >= size_of(winapi.DEVICE_SEEK_PENALTY_DESCRIPTOR)

		model := desc.product
		if desc.vendor != "" && desc.product != "" && !strings.has_prefix(desc.product, desc.vendor) {
			model = fmt.tprintf("%s %s", desc.vendor, desc.product)
		} else if model == "" {
			model = desc.vendor
		}
		kind := has_desc ? winapi.disk_kind_from_properties(desc.bus_type, desc.removable, bool(has_seek), sp.IncursSeekPenalty != 0) : "Disk"
		mounts := mounts_by_disk[u32(n)]
		append(out, Disk_Info{
			name     = fmt.tprintf("PhysicalDrive%d", n),
			model    = model,
			kind     = kind,
			capacity = u64(max(cap_bytes, 0)),
			mounts   = mounts[:],
		})
	}
}

// Lists network adapters via GetAdaptersAddresses with friendly name, link kind, MAC, speed, and IPv4/IPv6 addresses.
nets_list :: proc(out: ^[dynamic]Net_Info) {
	flags := win.GAA_Flags{.Skip_Anycast, .Skip_Multicast, .Skip_DNS_Server}
	size := u32(32 * 1024)
	buf := win_bytes(int(size))
	rc := win.GetAdaptersAddresses(.Unspecified, flags, nil, (^win.IP_Adapter_Addresses)(raw_data(buf)), &size)
	if rc == u32(WIN_ERROR_BUFFER_OVERFLOW) && size > 0 {
		buf = win_bytes(int(size))
		rc = win.GetAdaptersAddresses(.Unspecified, flags, nil, (^win.IP_Adapter_Addresses)(raw_data(buf)), &size)
	}
	if rc != 0 { return }

	for cur := (^win.IP_Adapter_Addresses)(raw_data(buf)); cur != nil; cur = cur.Next {
		if cur.IfType == IF_TYPE_SOFTWARE_LOOPBACK { continue }
		name := cur.FriendlyName != nil ? win_wstr_to_utf8(([^]u16)(cur.FriendlyName), 256, context.temp_allocator) : ""
		if name == "" { continue }

		kind := "Virtual"
		switch cur.IfType {
		case IF_TYPE_ETHERNET_CSMACD: kind = "Ethernet"
		case IF_TYPE_IEEE80211:       kind = "Wi-Fi"
		case IF_TYPE_TUNNEL, IF_TYPE_PPP: kind = "Tunnel"
		}

		mac := ""
		if cur.PhysicalAddressLength == 6 {
			a := cur.PhysicalAddress
			mac = fmt.tprintf("%02x:%02x:%02x:%02x:%02x:%02x", a[0], a[1], a[2], a[3], a[4], a[5])
		}

		up := cur.OperStatus == .Up
		link_bps := max(cur.TransmitLinkSpeed, cur.ReceiveLinkSpeed)
		speed_mbps := 0
		// Ignore sentinel max(u64) reported by disconnected/virtual adapters.
		if up && link_bps > 0 && link_bps < max(u64) / 2 {
			speed_mbps = int(link_bps / 1_000_000)
		}

		v4 := make([dynamic]string, 0, 2, context.temp_allocator)
		v6 := make([dynamic]string, 0, 2, context.temp_allocator)
		for ua := cur.FirstUnicastAddress; ua != nil; ua = ua.Next {
			sa := ua.Address.lpSockaddr
			if sa == nil { continue }
			if sa.sa_family == u16(win.AF_INET) && ua.Address.iSockaddrLength >= size_of(win.sockaddr_in) {
				sin := (^win.sockaddr_in)(sa)
				b := transmute([4]u8)sin.sin_addr.s_addr
				append(&v4, net.address_to_string(net.IP4_Address{b[0], b[1], b[2], b[3]}, context.temp_allocator))
			} else if sa.sa_family == u16(win.AF_INET6) && ua.Address.iSockaddrLength >= size_of(win.sockaddr_in6) {
				sin6 := (^win.sockaddr_in6)(sa)
				ip6: net.IP6_Address
				raw6 := sin6.sin6_addr.s6_addr
				for k in 0 ..< 8 { ip6[k] = u16be(u16(raw6[2 * k]) << 8 | u16(raw6[2 * k + 1])) }
				append(&v6, net.address_to_string(ip6, context.temp_allocator))
			}
		}
		addrs := make([dynamic]string, 0, len(v4) + len(v6), context.temp_allocator)
		for a in v4 { append(&addrs, a) }
		for a in v6 { append(&addrs, a) }

		append(out, Net_Info{
			name       = name,
			kind       = kind,
			mac        = mac,
			up         = up,
			speed_mbps = speed_mbps,
			addrs      = addrs[:],
		})
	}
}
