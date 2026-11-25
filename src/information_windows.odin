package inspecteur

// Windows System Information model (direct native APIs, zero WMI, zero subprocesses):
// - Edition, DisplayVersion, Build, and UBR from Registry CurrentVersion (correct Windows 11 >= 22000 label).
// - Elevation status (Administrator vs Standard user).
// - SMBIOS firmware/motherboard/computer identity via GetSystemFirmwareTable('RSMB').
// - CPU topology via cpu_info_read(); Graphics adapters via DXGI; Volumes via GetVolumeInformationW + GetDiskFreeSpaceExW;
//   Displays via EnumDisplayDevicesW + EnumDisplaySettingsW + EDID registry; Batteries via GetSystemPowerStatus + IOCTL_BATTERY_QUERY_*.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "vendor:directx/dxgi"
import i18n "gt:i18n"
import tasks "gt:tasks"
import "gt:ui"
import winapi "winapi"

Win_Info_Gpu :: struct {
	name:       string,
	vendor:     string,
	ids:        string,
	vram_bytes: u64,
	shared_mem: u64,
}

Win_Info_Volume :: struct {
	drive: string,
	label: string,
	fs:    string,
	size:  u64,
	free:  u64,
}

Win_Info_Display :: struct {
	device: string,
	name:   string,
	mode:   string,
}

Win_Info_Battery :: struct {
	name:     string,
	status:   string,
	capacity: int,
	health:   int,   // -1: unavailable
}

Info_Static :: struct {
	arena:     virtual.Arena,
	os_name:   string,
	build:     string,
	arch:      string,
	hostname:  string,
	elevated:  bool,
	computer:  string,
	board:     string,
	firmware:  string,
	cpu:       Cpu_Info,
	gpus:      [dynamic]Win_Info_Gpu,
	volumes:   [dynamic]Win_Info_Volume,
	displays:  [dynamic]Win_Info_Display,
	batteries: [dynamic]Win_Info_Battery,
}

Information :: struct {
	job:   tasks.Job,
	demo:  ^Demo,
	state: ^ui.State,
	data:  ^Info_Static,
	asked: bool,
}

information_init :: proc(inf: ^Information, app: ^App) {
	inf.demo  = app.demo
	inf.state = &app.main.state
	inf.job   = {work = win_information_work, data = inf}
}

information_destroy :: proc(inf: ^Information) {
	win_info_free(inf.data)
}

@(private = "file")
win_info_free :: proc(s: ^Info_Static) {
	if s == nil { return }
	virtual.arena_destroy(&s.arena)
	free(s)
}

information_ask :: proc(inf: ^Information) {
	inf.asked = true
	tasks.job_ask(ui.chores(), &inf.job)
}

information_busy :: proc(inf: ^Information) -> bool { return tasks.job_busy(ui.chores(), &inf.job) }

@(private = "file")
win_information_work :: proc(data: rawptr) {
	inf := (^Information)(data)
	s := new(Info_Static)
	{
		context.allocator = virtual.arena_allocator(&s.arena)
		if inf.demo != nil { demo_info_read(s) } else { win_info_read(s) }
	}
	if !ui.post(inf.state, win_information_posted, s) { win_info_free(s) }
}

@(private = "file")
win_information_posted :: proc(data: rawptr, _: u64) {
	s := (^Info_Static)(data)
	if the_app == nil { win_info_free(s); return }
	inf := &the_app.information
	win_info_free(inf.data)
	inf.data = s
}

////////////////////////////////
// Native Windows system readers

win_info_read :: proc(s: ^Info_Static) {
	a := context.allocator

	// Windows edition, display version, build, and UBR.
	CV :: "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"
	prod, _   := win_reg_read_string(win.HKEY_LOCAL_MACHINE, CV, "ProductName")
	disp, _   := win_reg_read_string(win.HKEY_LOCAL_MACHINE, CV, "DisplayVersion")
	build_s, _ := win_reg_read_string(win.HKEY_LOCAL_MACHINE, CV, "CurrentBuildNumber")
	ubr, has_ubr := win_reg_read_dword(win.HKEY_LOCAL_MACHINE, CV, "UBR")
	build_num := strconv.parse_int(build_s, 10) or_else 0
	// Windows 11 builds (>= 22000) still report "Windows 10 ..." in Registry ProductName for app compat.
	if build_num >= 22000 && strings.has_prefix(prod, "Windows 10") {
		prod, _ = strings.replace(prod, "Windows 10", "Windows 11", 1, context.temp_allocator)
	}
	if prod == "" { prod = "Windows" }
	s.os_name = disp != "" ? fmt.aprintf("%s %s", prod, disp, allocator = a) : strings.clone(prod, a)
	if build_s != "" {
		s.build = has_ubr ? fmt.aprintf("%s.%d", build_s, ubr, allocator = a) : strings.clone(build_s, a)
	}

	arch := os.get_env("PROCESSOR_ARCHITEW6432", context.temp_allocator)
	if arch == "" { arch = os.get_env("PROCESSOR_ARCHITECTURE", context.temp_allocator) }
	if arch == "" { arch = "AMD64" }
	s.arch = strings.clone(arch, a)

	host := os.get_env("COMPUTERNAME", context.temp_allocator)
	s.hostname = strings.clone(host, a)
	s.elevated = win_is_elevated()

	// SMBIOS hardware info via GetSystemFirmwareTable('RSMB').
	if d := win_dyn(); d.GetSystemFirmwareTable != nil {
		// 'RSMB' in big-endian DWORD signature = 0x52534D42.
		RSMB :: u32(0x52534D42)
		sz := d.GetSystemFirmwareTable(RSMB, 0, nil, 0)
		if sz > 0 && sz < 4 * 1024 * 1024 {
			raw := win_bytes(int(sz))
			if got := d.GetSystemFirmwareTable(RSMB, 0, raw_data(raw), sz); got > 0 {
				if sm, ok := winapi.decode_smbios(raw[:min(int(got), len(raw))], context.temp_allocator); ok {
					s.computer = strings.clone(join_pair(sm.sys_vendor, sm.sys_product), a)
					s.board    = strings.clone(join_pair(sm.board_vendor, sm.board_product), a)
					fw_parts := make([dynamic]string, context.temp_allocator)
					if sm.bios_vendor != "" { append(&fw_parts, sm.bios_vendor) }
					if sm.bios_version != "" { append(&fw_parts, sm.bios_version) }
					if sm.bios_date != "" { append(&fw_parts, sm.bios_date) }
					s.firmware = strings.clone(strings.join(fw_parts[:], " ", context.temp_allocator), a)
				}
			}
		}
	}

	s.cpu = cpu_info_read()   // (its model in context.allocator: the arena)

	// GPUs via DXGI.
	win_info_gpus(s, a)

	// Mounted NTFS / ReFS / FAT volumes.
	win_info_volumes(s, a)

	// Displays via EnumDisplayDevicesW + EnumDisplaySettingsW.
	win_info_displays(s, a)

	// Batteries via GetSystemPowerStatus + IOCTL_BATTERY_QUERY_*.
	win_info_batteries(s, a)
}

@(private = "file")
join_pair :: proc(a, b: string) -> string {
	if a == "" { return b }
	if b == "" { return a }
	if strings.has_prefix(b, a) { return b }
	return fmt.tprintf("%s %s", a, b)
}

@(private = "file")
win_info_gpus :: proc(s: ^Info_Static, a: mem.Allocator) {
	factory_ptr: rawptr
	if dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, &factory_ptr) < 0 || factory_ptr == nil { return }
	factory := (^dxgi.IFactory1)(factory_ptr)
	defer factory->Release()

	for idx := u32(0); idx < 8; idx += 1 {
		adapter: ^dxgi.IAdapter1
		if factory->EnumAdapters1(idx, &adapter) < 0 || adapter == nil { break }
		desc: dxgi.ADAPTER_DESC1
		ok := adapter->GetDesc1(&desc) >= 0
		adapter->Release()
		if !ok { continue }
		if .SOFTWARE in desc.Flags || (desc.VendorId == 0x1414 && desc.DeviceId == 0x008C) { continue }
		vendor := "GPU"
		switch desc.VendorId {
		case 0x10DE: vendor = "NVIDIA"
		case 0x1002: vendor = "AMD"
		case 0x8086: vendor = "Intel"
		}
		append(&s.gpus, Win_Info_Gpu{
			name       = win_utf16_to_utf8(desc.Description[:], a),
			vendor     = vendor,
			ids        = fmt.aprintf("%04x:%04x", desc.VendorId, desc.DeviceId, allocator = a),
			vram_bytes = u64(desc.DedicatedVideoMemory),
			shared_mem = u64(desc.SharedSystemMemory),
		})
	}
}

@(private = "file")
win_info_volumes :: proc(s: ^Info_Static, a: mem.Allocator) {
	defer_mode: proc "system" (mode: win.DWORD, old: ^win.DWORD) -> win.BOOL
	defer_old: win.DWORD
	k32 := win.GetModuleHandleW(win.L("kernel32.dll"))
	if k32 == nil { return }
	// (a drive with no medium answers with an error, not with a dialog of the system)
	if SetThreadErrorMode := (proc "system" (mode: win.DWORD, old: ^win.DWORD) -> win.BOOL)(win.GetProcAddress(k32, "SetThreadErrorMode")); SetThreadErrorMode != nil {
		SEM_FAILCRITICALERRORS :: win.DWORD(0x0001)
		old: win.DWORD
		if SetThreadErrorMode(SEM_FAILCRITICALERRORS, &old) { defer_mode, defer_old = SetThreadErrorMode, old }
	}
	defer if defer_mode != nil { defer_mode(defer_old, nil) }
	GetLogicalDriveStringsW := (proc "system" (n: win.DWORD, buf: [^]u16) -> win.DWORD)(win.GetProcAddress(k32, "GetLogicalDriveStringsW"))
	GetVolumeInformationW   := (proc "system" (root: win.LPCWSTR, vol_name: [^]u16, vol_sz: win.DWORD, serial, max_comp, flags: ^win.DWORD, fs_name: [^]u16, fs_sz: win.DWORD) -> win.BOOL)(win.GetProcAddress(k32, "GetVolumeInformationW"))
	if GetLogicalDriveStringsW == nil { return }

	wbuf: [512]u16
	n := GetLogicalDriveStringsW(len(wbuf), &wbuf[0])
	if n == 0 || int(n) >= len(wbuf) { return }
	i := 0
	for i < int(n) && wbuf[i] != 0 {
		start := i
		for i < int(n) && wbuf[i] != 0 { i += 1 }
		drive := win_utf16_to_utf8(wbuf[start:i], context.temp_allocator)
		i += 1
		if drive == "" { continue }
		wdrive := win.utf8_to_wstring(drive, context.temp_allocator)
		avail, total, free_b: win.ULARGE_INTEGER
		if !win.GetDiskFreeSpaceExW(wdrive, &avail, &total, &free_b) || total == 0 { continue }
		vname, fs := "", ""
		if GetVolumeInformationW != nil {
			vb: [128]u16
			fb: [64]u16
			if GetVolumeInformationW(wdrive, &vb[0], len(vb), nil, nil, nil, &fb[0], len(fb)) {
				vname = win_utf16_to_utf8(vb[:], context.temp_allocator)
				fs    = win_utf16_to_utf8(fb[:], context.temp_allocator)
			}
		}
		append(&s.volumes, Win_Info_Volume{
			drive = strings.clone(drive, a),
			label = strings.clone(vname, a),
			fs    = strings.clone(fs, a),
			size  = u64(total),
			free  = u64(avail),
		})
	}
}

@(private = "file")
win_info_displays :: proc(s: ^Info_Static, a: mem.Allocator) {
	ENUM_CURRENT_SETTINGS :: win.DWORD(0xFFFFFFFF)
	DISPLAY_DEVICE_ACTIVE :: win.DWORD(0x00000001)
	for dev_idx := win.DWORD(0); dev_idx < 16; dev_idx += 1 {
		dd := win.DISPLAY_DEVICEW{cb = size_of(win.DISPLAY_DEVICEW)}
		if !win.EnumDisplayDevicesW(nil, dev_idx, &dd, 0) { break }
		if (dd.StateFlags & DISPLAY_DEVICE_ACTIVE) == 0 { continue }
		dev_name := win_utf16_to_utf8(dd.DeviceName[:], context.temp_allocator)
		mon_name := win_utf16_to_utf8(dd.DeviceString[:], context.temp_allocator)

		// Query attached monitor friendly name and EDID product name if present.
		mon := win.DISPLAY_DEVICEW{cb = size_of(win.DISPLAY_DEVICEW)}
		if win.EnumDisplayDevicesW(cstring16(&dd.DeviceName[0]), 0, &mon, 0) {
			if mstr := win_utf16_to_utf8(mon.DeviceString[:], context.temp_allocator); mstr != "" { mon_name = mstr }
			if edid_name := win_edid_from_device_id(win_utf16_to_utf8(mon.DeviceID[:], context.temp_allocator)); edid_name != "" {
				mon_name = edid_name
			}
		}

		dm := win.DEVMODEW{dmSize = size_of(win.DEVMODEW)}
		mode := ""
		if win.EnumDisplaySettingsW(cstring16(&dd.DeviceName[0]), ENUM_CURRENT_SETTINGS, &dm) {
			if dm.dmDisplayFrequency > 0 {
				mode = fmt.tprintf("%d×%d, %d Hz", dm.dmPelsWidth, dm.dmPelsHeight, dm.dmDisplayFrequency)
			} else {
				mode = fmt.tprintf("%d×%d", dm.dmPelsWidth, dm.dmPelsHeight)
			}
		}
		append(&s.displays, Win_Info_Display{
			device = strings.clone(dev_name, a),
			name   = strings.clone(mon_name, a),
			mode   = strings.clone(mode, a),
		})
	}
}

// Looks up Monitor EDID bytes in Registry (SYSTEM\CurrentControlSet\Enum\DISPLAY\<id>\...\Device Parameters\EDID).
@(private = "file")
win_edid_from_device_id :: proc(dev_id: string) -> string {
	// DeviceID looks like "MONITOR\\DELA1C2\\{4d36e96e-...}\\0001"
	parts := strings.split(dev_id, "\\", context.temp_allocator)
	if len(parts) < 2 || parts[1] == "" { return "" }
	base := fmt.tprintf("SYSTEM\\CurrentControlSet\\Enum\\DISPLAY\\%s", parts[1])
	hk: win.HKEY
	if win.RegOpenKeyExW(win.HKEY_LOCAL_MACHINE, win.utf8_to_wstring(base, context.temp_allocator), 0, win.KEY_READ, &hk) != 0 {
		return ""
	}
	defer win.RegCloseKey(hk)
	sub_buf: [256]u16
	sub_len := win.DWORD(len(sub_buf))
	if win.RegEnumKeyExW(hk, 0, &sub_buf[0], &sub_len, nil, nil, nil, nil) != 0 { return "" }
	inst := win_utf16_to_utf8(sub_buf[:int(sub_len)], context.temp_allocator)
	edid_key := fmt.tprintf("%s\\%s\\Device Parameters", base, inst)
	if raw, ok := win_reg_read_binary(win.HKEY_LOCAL_MACHINE, edid_key, "EDID"); ok {
		return winapi.decode_edid_name(raw, context.temp_allocator)
	}
	return ""
}

@(private = "file")
win_info_batteries :: proc(s: ^Info_Static, a: mem.Allocator) {
	sps: win.SYSTEM_POWER_STATUS
	if !win.GetSystemPowerStatus(&sps) { return }
	if .No_Battery in sps.BatteryFlag || sps.BatteryLifePercent == 255 { return }

	status := i18n.tr("discharging")
	if .Charging in sps.BatteryFlag {
		status = i18n.tr("charging")
	} else if sps.ACLineStatus == .Online {
		status = sps.BatteryLifePercent >= 99 ? i18n.tr("full") : i18n.tr("plugged in")
	}
	health := win_query_battery_health()
	append(&s.batteries, Win_Info_Battery{
		name     = strings.clone(i18n.tr("System battery"), a),
		status   = strings.clone(status, a),
		capacity = int(sps.BatteryLifePercent),
		health   = health,
	})
}

// Reads design vs full-charge capacity (health %) via SetupDiGetClassDevsW(GUID_DEVINTERFACE_BATTERY) + IOCTL_BATTERY_QUERY_*.
@(private = "file")
win_query_battery_health :: proc() -> int {
	lib := win_system_library("setupapi.dll")
	if lib == nil { return -1 }
	defer win.FreeLibrary(lib)

	SetupDiGetClassDevsW              := (proc "system" (guid: ^win.GUID, enumerator: win.LPCWSTR, hwnd: win.HWND, flags: win.DWORD) -> win.HANDLE)(win.GetProcAddress(lib, "SetupDiGetClassDevsW"))
	SetupDiEnumDeviceInterfaces       := (proc "system" (h: win.HANDLE, info: rawptr, guid: ^win.GUID, idx: win.DWORD, out: rawptr) -> win.BOOL)(win.GetProcAddress(lib, "SetupDiEnumDeviceInterfaces"))
	SetupDiGetDeviceInterfaceDetailW  := (proc "system" (h: win.HANDLE, iface: rawptr, detail: rawptr, detail_sz: win.DWORD, req_sz: ^win.DWORD, info: rawptr) -> win.BOOL)(win.GetProcAddress(lib, "SetupDiGetDeviceInterfaceDetailW"))
	SetupDiDestroyDeviceInfoList      := (proc "system" (h: win.HANDLE) -> win.BOOL)(win.GetProcAddress(lib, "SetupDiDestroyDeviceInfoList"))
	if SetupDiGetClassDevsW == nil || SetupDiEnumDeviceInterfaces == nil || SetupDiGetDeviceInterfaceDetailW == nil || SetupDiDestroyDeviceInfoList == nil {
		return -1
	}

	GUID_DEVINTERFACE_BATTERY := win.GUID{0x72631e54, 0x78A4, 0x11d0, {0xbc, 0xf7, 0x00, 0xaa, 0x00, 0xb7, 0xb3, 0x2a}}
	DIGCF_PRESENT         :: win.DWORD(0x00000002)
	DIGCF_DEVICEINTERFACE :: win.DWORD(0x00000010)
	hdev := SetupDiGetClassDevsW(&GUID_DEVINTERFACE_BATTERY, nil, nil, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE)
	if hdev == nil || hdev == win.INVALID_HANDLE_VALUE { return -1 }
	defer SetupDiDestroyDeviceInfoList(hdev)

	did := winapi.SP_DEVICE_INTERFACE_DATA64{cbSize = size_of(winapi.SP_DEVICE_INTERFACE_DATA64)}
	if !SetupDiEnumDeviceInterfaces(hdev, nil, &GUID_DEVINTERFACE_BATTERY, 0, &did) { return -1 }

	req: win.DWORD
	_ = SetupDiGetDeviceInterfaceDetailW(hdev, &did, nil, 0, &req, nil)
	if req < 8 || req > 4096 { return -1 }
	dbuf := win_bytes(int(req) + 8)
	// cbSize on 64-bit Windows is 8 for SP_DEVICE_INTERFACE_DETAIL_DATA_W (4-byte cbSize + 2-byte WCHAR[1] + 2 pad).
	cb := win.DWORD(8)
	mem.copy(raw_data(dbuf), &cb, 4)
	if !SetupDiGetDeviceInterfaceDetailW(hdev, &did, raw_data(dbuf), req, nil, nil) { return -1 }
	dev_path := ([^]u16)(&dbuf[4])

	bh := win.CreateFileW(cstring16(dev_path), win.GENERIC_READ | win.GENERIC_WRITE, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, nil, win.OPEN_EXISTING, 0, nil)
	if bh == win.INVALID_HANDLE_VALUE { return -1 }
	defer win.CloseHandle(bh)

	IOCTL_BATTERY_QUERY_TAG         :: win.DWORD(0x00294040)
	IOCTL_BATTERY_QUERY_INFORMATION :: win.DWORD(0x00294044)
	wait_ms: u32
	tag: u32
	got: win.DWORD
	if !win.DeviceIoControl(bh, IOCTL_BATTERY_QUERY_TAG, &wait_ms, size_of(wait_ms), &tag, size_of(tag), &got, nil) || tag == 0 {
		return -1
	}

	BATTERY_QUERY_INFORMATION :: struct {
		BatteryTag:       u32,
		InformationLevel: u32,   // 0 = BatteryInformation
		AtRate:           i32,
	}
	BATTERY_INFORMATION :: struct {
		Capabilities:        u32,
		Technology:          u8,
		Reserved:            [3]u8,
		Chemistry:           [4]u8,
		DesignedCapacity:    u32,
		FullChargedCapacity: u32,
		DefaultAlert1:       u32,
		DefaultAlert2:       u32,
		CriticalBias:        u32,
		CycleCount:          u32,
	}
	bqi := BATTERY_QUERY_INFORMATION{BatteryTag = tag, InformationLevel = 0}
	bi: BATTERY_INFORMATION
	if !win.DeviceIoControl(bh, IOCTL_BATTERY_QUERY_INFORMATION, &bqi, size_of(bqi), &bi, size_of(bi), &got, nil) {
		return -1
	}
	if bi.DesignedCapacity == 0 || bi.FullChargedCapacity == 0 { return -1 }
	return int((u64(bi.FullChargedCapacity) * 100) / u64(bi.DesignedCapacity))
}
