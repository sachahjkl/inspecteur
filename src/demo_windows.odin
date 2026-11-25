package inspecteur

// Demo data for Windows sections (SCM Services, StartupApproved + Task Scheduler,
// Windows System Information, and 7-tab Windows Properties).

import "core:fmt"
import "core:mem"
import "core:strings"
import i18n "gt:i18n"

@(private = "file")
DEMO_WIN_SERVICES := [?]Win_Service{
	{name = "AudioSrv", display_name = "Windows Audio", state = .Running, startup_type = .Automatic, pid = 1820, account = "NT AUTHORITY\\LocalService", svchost_group = "LocalServiceNetworkRestricted", binary_path = "C:\\Windows\\System32\\svchost.exe -k LocalServiceNetworkRestricted -p", can_stop = true},
	{name = "Dhcp", display_name = "DHCP Client", state = .Running, startup_type = .Automatic, pid = 1420, account = "NT AUTHORITY\\LocalService", svchost_group = "LocalServiceNetworkRestricted", binary_path = "C:\\Windows\\System32\\svchost.exe -k LocalServiceNetworkRestricted -p", can_stop = true},
	{name = "Dnscache", display_name = "DNS Client", state = .Running, startup_type = .Automatic, pid = 1360, account = "NT AUTHORITY\\NetworkService", svchost_group = "NetworkService", binary_path = "C:\\Windows\\System32\\svchost.exe -k NetworkService -p", can_stop = false},
	{name = "EventLog", display_name = "Windows Event Log", state = .Running, startup_type = .Automatic, pid = 1280, account = "NT AUTHORITY\\LocalService", svchost_group = "LocalServiceNetworkRestricted", binary_path = "C:\\Windows\\System32\\svchost.exe -k LocalServiceNetworkRestricted -p", can_stop = true},
	{name = "Spooler", display_name = "Print Spooler", state = .Stopped, startup_type = .Automatic, pid = 0, account = "LocalSystem", binary_path = "C:\\Windows\\System32\\spoolsv.exe", can_stop = true},
	{name = "WinDefend", display_name = "Microsoft Defender Antivirus Service", state = .Running, startup_type = .Automatic, pid = 2410, account = "LocalSystem", binary_path = "\"C:\\ProgramData\\Microsoft\\Windows Defender\\Platform\\MsMpEng.exe\"", protection = 3, can_stop = false},
	{name = "wuauserv", display_name = "Windows Update", state = .Stopped, startup_type = .Manual, pid = 0, account = "LocalSystem", svchost_group = "netsvcs", binary_path = "C:\\Windows\\System32\\svchost.exe -k netsvcs -p", can_stop = true},
}

@(private = "file")
DEMO_WIN_DRIVERS := [?]Win_Service{
	{name = "Ntfs", display_name = "NTFS File System Driver", state = .Running, startup_type = .Boot, binary_path = "System32\\drivers\\ntfs.sys", is_driver = true},
	{name = "nvlddmkm", display_name = "NVIDIA Display Driver", state = .Running, startup_type = .Manual, binary_path = "System32\\DriverStore\\FileRepository\\nvlddmkm.sys", is_driver = true},
}

demo_services_read :: proc(d: ^Demo, filter: Win_Service_Filter, out: ^[dynamic]Win_Service, a: mem.Allocator) -> string {
	_ = d
	if filter == .Drivers {
		for s in DEMO_WIN_DRIVERS { append(out, s) }
		return ""
	}
	for s in DEMO_WIN_SERVICES {
		if filter == .Shared && s.svchost_group == "" { continue }
		append(out, s)
	}
	return ""
}

demo_service_details :: proc(d: ^Demo, det: ^Win_Service_Details, a: mem.Allocator) {
	_ = d
	for s in DEMO_WIN_SERVICES {
		if s.name != det.name { continue }
		det.binary_path   = strings.clone(s.binary_path, a)
		det.account       = strings.clone(s.account, a)
		det.svchost_group = strings.clone(s.svchost_group, a)
		det.protection    = strings.clone(win_service_protection_label(s.protection), a)
		det.description   = strings.clone(s.display_name, a)
		append(&det.dependencies, "RpcSs")
		append(&det.events,
			Win_Event_Entry{timestamp = "2026-11-25 09:01:12", level = 4, event_id = 7036, provider = "Service Control Manager", message = fmt.aprintf("The %s service entered the running state.", s.display_name, allocator = a)},
			Win_Event_Entry{timestamp = "2026-11-25 09:01:10", level = 4, event_id = 7040, provider = "Service Control Manager", message = fmt.aprintf("The start type of %s service is Automatic.", s.display_name, allocator = a)},
		)
		return
	}
	det.event_problem = strings.clone(i18n.tr("No recent entries for this service in the System Event Log."), a)
}

demo_startup_read :: proc(d: ^Demo, out: ^[dynamic]Win_Startup_Item, a: mem.Allocator) -> string {
	_ = d
	append(out,
		Win_Startup_Item{source = .HKCU_Run, id = "OneDrive", name = "OneDrive", command = "\"C:\\Users\\alex\\AppData\\Local\\Microsoft\\OneDrive\\OneDrive.exe\" /background", location = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run", target_path = "C:\\Users\\alex\\AppData\\Local\\Microsoft\\OneDrive\\OneDrive.exe", enabled = true, status = i18n.tr("Enabled"), can_toggle = true},
		Win_Startup_Item{source = .HKLM_Run, id = "SecurityHealth", name = "Windows Security notification icon", command = "%windir%\\system32\\SecurityHealthSystray.exe", location = "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Run", target_path = "C:\\Windows\\System32\\SecurityHealthSystray.exe", enabled = true, status = i18n.tr("Enabled"), can_toggle = true, needs_admin = true},
		Win_Startup_Item{source = .User_Folder, id = "Syncthing.lnk", name = "Syncthing", command = "C:\\Program Files\\Syncthing\\syncthing.exe --no-console", location = "C:\\Users\\alex\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup\\Syncthing.lnk", target_path = "C:\\Program Files\\Syncthing\\syncthing.exe", enabled = false, status = i18n.tr("Disabled"), can_toggle = true},
		Win_Startup_Item{source = .Task_Scheduler, id = "PowerToys", name = "PowerToys Autorun", command = "C:\\Program Files\\PowerToys\\PowerToys.exe", location = "C:\\Windows\\System32\\Tasks\\PowerToys", target_path = "C:\\Program Files\\PowerToys\\PowerToys.exe", enabled = true, status = i18n.tr("Enabled"), can_toggle = false, needs_admin = true},
	)
	_ = a
	return ""
}

demo_info_read :: proc(s: ^Info_Static) {
	s.os_name  = "Windows 11 Pro 24H2"
	s.build    = "26100.2605"
	s.arch     = "AMD64"
	s.hostname = "WORKSTATION"
	s.elevated = false
	s.computer = "ASUS System Product"
	s.board    = "ASUSTeK COMPUTER INC. TUF GAMING B650-PLUS"
	s.firmware = "American Megatrends Inc. 1813 10/14/2024"
	s.cpu      = demo_cpu_info()
	append(&s.gpus, Win_Info_Gpu{name = "NVIDIA GeForce RTX 4070", vendor = "NVIDIA", ids = "10de:2786", vram_bytes = 12 * 1024 * 1024 * 1024})
	append(&s.volumes,
		Win_Info_Volume{drive = "C:\\", label = "Windows", fs = "NTFS", size = 980 * 1024 * 1024 * 1024, free = 512 * 1024 * 1024 * 1024},
		Win_Info_Volume{drive = "D:\\", label = "Data", fs = "NTFS", size = 3700 * 1024 * 1024 * 1024, free = 2100 * 1024 * 1024 * 1024},
	)
	append(&s.displays, Win_Info_Display{device = "\\\\.\\DISPLAY1", name = "DELL U2723QE", mode = "3840×2160, 60 Hz"})
}

demo_props_read :: proc(d: ^Demo, pid: i32, p: ^Props_Data, a: mem.Allocator) {
	q, ok := demo_proc_of(pid)
	if !ok { p.cwd_read, p.list_read, p.sec_read = .Gone, .Gone, .Gone; return }
	p.cwd, p.cwd_read, p.list_read, p.sec_read = "C:\\Users\\alex", .Read, .Read, .Read
	p.cpus = fmt.aprintf("0-%d", DEMO_LOGICAL - 1, allocator = a)
	p.gdi_objects, p.gdi_peak = 42, 64
	p.user_objects, p.user_peak = 28, 35
	switch p.read_tab {
	case .General, .History:
	case .Security:
		append(&p.privileges,
			Win_Privilege_Row{"SeChangeNotifyPrivilege", i18n.tr("Enabled (default)")},
			Win_Privilege_Row{"SeShutdownPrivilege", i18n.tr("Disabled")},
			Win_Privilege_Row{"SeUndockPrivilege", i18n.tr("Disabled")},
		)
	case .Threads:
		for k in 0 ..< int(q.threads) {
			append(&p.threads, Win_Thread_Row{
				tid = q.pid + i32(k), state = i18n.tr("Waiting"), wait_reason = "UserRequest",
				cpu_ns = u64(1 + k * 2) * 1_000_000_000 / u64(k + 1), priority = 8,
			})
		}
	case .Handles:
		append(&p.handles,
			Win_Handle_Row{0x0044, "File", 0x00120089, "\\Device\\HarddiskVolume3\\Users\\alex\\Documents"},
			Win_Handle_Row{0x0088, "Key", 0x00020019, "\\REGISTRY\\USER\\S-1-5-21\\Software\\FromentSoftware"},
			Win_Handle_Row{0x00C0, "Mutant", 0x001F0001, "\\Sessions\\1\\BaseNamedObjects\\InspecteurLock"},
		)
		p.handles_total = 3
	case .Modules:
		append(&p.modules,
			Win_Module_Row{"C:\\Windows\\System32\\ntdll.dll", 0x00007FF8A0000000, 2_200_000},
			Win_Module_Row{"C:\\Windows\\System32\\kernel32.dll", 0x00007FF89F000000, 810_000},
			Win_Module_Row{"C:\\Windows\\System32\\user32.dll", 0x00007FF89E000000, 1_750_000},
		)
	case .Environment:
		append(&p.env, "COMPUTERNAME=WORKSTATION", "LOCALAPPDATA=C:\\Users\\alex\\AppData\\Local", "OS=Windows_NT", "USERNAME=alex")
	}
	_ = d
}
