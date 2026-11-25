# The system and the views; platform ports

## The rule

Windows, Linux, and macOS are different systems.
Do not force one system into the shape of another.

Share only what means the same thing on every system:

- The window chrome, sidebar, footer, theme, palette engine, settings engine, and views layout.
- The process table widget, virtual list, sorting, filtering, selection, histories, graphs, and rate math.
- Performance counters and graphs (`machine.odin`, `gpu.odin`, `perf_view.odin`).
- Network sockets (`connections.odin`, `connections_view.odin`).

Keep every system call and every platform-divergent section in whole files chosen by Odin's build suffix (`*_linux.odin`, `*_windows.odin`, `*_other.odin`, or `#+build !windows`).
Do not sprinkle `when ODIN_OS` checks inside shared views or models.
Do not add descriptor tables, plugin interfaces, or lowest-common structs with fields that stay empty on one system.
Duplicate a few lines in a platform view rather than share a wrong abstraction.

## Counters, not rates

A reader gives raw counters, not rates: a process's CPU time since it started, a disk's bytes since boot.
The shared side computes rates (`rate_of`, `busy_percent`), CPU percentages, and graph points, and keeps history for each process and device.
The arithmetic stays identical across systems and runs in unit tests without live OS calls.

## Pure binary decoders

System readers that parse binary kernel or OS buffers put their struct definitions and decoders in a pure sub-package (`src/winapi` for Windows).
Every struct layout carries compile-time `#assert` checks on `size_of` and `offset_of` against the OS headers for 64-bit (`amd64` and `arm64`) and 32-bit WOW64 layouts.
Pure decoders take byte slices, guard against truncated or hostile buffers, and run in unit tests on every host OS.

## The demo is a third source

The demo (`demo.odin`, `demo_other.odin`, `demo_windows.odin`, started with `inspecteur --demo`) is a third source behind the same procedures.
Documentation screenshots use the demo so they contain no data from the host machine.

## Windows calls

Libraries come from the system's folder alone (`win_system_library`): most are not KnownDLLs, and a file of their name beside the program would run.
A buffer given to a system call is aligned (`win_bytes`).

## Limits of the Windows readers

- Efficiency mode, the integrity and the services of a process are read once, when it is first seen.
- The GPUs are listed once: a driver's restart gives them new LUIDs, which the counters then do not match.
- `CallNtPowerInformation` gives the nominal frequency on most recent processors.
- Task Scheduler's folder and the files of other users' processes are an administrator's.

## Systems without a port

macOS (`darwin`) keeps `*_other.odin` stubs (`#+build !linux` and `#+build !windows`) so cross-target checks catch missing symbols and broken portable code.
The stubs return empty lists, `proc_reader_init` returns false, and actions return `NOT_AVAILABLE`.

## Why platform-specific views exist

Four sections differ fundamentally between Linux and Windows:

- **Services**: Linux uses systemd over D-Bus with System and User managers, unit files, and `journald`.
  Windows uses the Service Control Manager (`advapi32.dll`) with one machine database, shared `svchost.exe` service groups, kernel and file-system drivers, Pause and Continue states, four startup types (including Automatic Delayed), Protected Process Light (PPL) services, and the Windows Event Log (`wevtapi.dll`).
  `services_windows.odin` and `services_view_windows.odin` model SCM directly instead of faking a `User` manager or systemd unit states.
- **Startup**: Linux uses XDG `.desktop` files and user systemd targets.
  Windows uses the `HKCU` `Run` key, the two `HKLM` ones (its 64-bit and its 32-bit WOW64 view; a user's `Software` has one view), User and Common Startup folders (`.lnk` shortcuts), Task Scheduler logon tasks, and the 12-byte `StartupApproved` registry binary state that Windows Task Manager reads and writes.
  `startup_windows.odin` and `startup_view_windows.odin` read and toggle all of these directly.
- **Properties**: Linux shows `/proc/<pid>/fd`, memory maps, and `nice`.
  Windows processes have kernel handles (where querying a synchronous named pipe hangs without timeout protection), GDI and USER object counts, token integrity levels, elevation status, PPL protection, critical-process flags, thread wait reasons, Wait Chain Traversal (deadlock analysis), Efficiency Mode (EcoQoS), UWP package identities, `svchost` service groups, and 64-bit plus WOW64 32-bit PEBs.
  `props_windows.odin` and `props_view_windows.odin` expose these natively in a Security and Resources tab, a Handles tab, and a Wait Chain view.
- **Information**: Linux reads `/etc/os-release`, `uname`, `/sys/class/dmi/id`, `pci.ids`, and `statfs`.
  Windows reads the Registry version keys (handling Windows 11 build numbers), SMBIOS tables (`GetSystemFirmwareTable`), DXGI adapters, NTFS/ReFS volumes, display EDID from the Registry, and battery design-versus-full capacity via `IOCTL_BATTERY_QUERY_INFORMATION`.
  `information_windows.odin` and `information_view_windows.odin` show Windows terms (Build, Edition, Privilege, Pagefile, Volumes) instead of Linux terms (Kernel, Swap, Desktop).

Process actions, columns, and commands also split cleanly:

- `columns_windows.odin` adds Windows columns (`Commit`, `Handles`, `Session`, `Integrity`, `Efficiency`, `Package`) and displays Windows priority classes (`Realtime`, `High`, `Above normal`, `Normal`, `Below normal`, `Idle`) instead of POSIX nice numbers.
- `acts_windows.odin` acts through one door, `win_open_for_act`: it verifies `(pid, creation_time)` on the opened `HANDLE`, refuses critical and protected (PPL) processes with the reason, and keeps that handle open until the one that acts is there. Windows gives a PID again only once no handle is open on its process. An unknown start time, or a protection that cannot be read, is a refusal.
- End task asks the visible windows to close. A process with no window is terminated; one whose windows do not take the message (an elevated one's) is not.
- Windows keeps the PID of a parent that ended and gives it again. `procs_read` drops a parent that started after its child (`winapi.true_parent`): End process tree, the groups and the guard of the ancestors rest on it.
- Efficiency mode off gives the choice back to the system (`ControlMask` 0): a controlled bit that is not set asks for the highest speed for good.
- With several processor groups the affinity is the process's default CPU sets, by their ids (`GetSystemCpuSetInformation`), never a mask.
- A service that running services need is not stopped, nor are they: the SCM refuses and the footer names them. An act waits (30 s at most) for the state it asked for.
- A File's name is asked on a raw thread with a bound: the query of a synchronous pipe may never answer, and neither a join nor the close of its handle may wait for it. A stuck thread owns its block; at most 16 are stuck at once.
- `commands_windows.odin` omits POSIX signals and systemd-only commands, and adds Efficiency Mode, Wait Chain analysis, SCM Pause/Continue, SCM startup types, and Event Log controls.

## Windows port file table

| File | Responsibility |
|---|---|
| `src/winapi/layouts.odin` | NT/Win32 binary struct layouts with `#assert` checks on `size_of` and `offset_of` (`amd64`, `arm64`, WOW64) |
| `src/winapi/decode.odin` | Pure decoders: `SYSTEM_PROCESS_INFORMATION`, processor performance, handles, PEB64/PEB32, TCP/UDP tables, `StartupApproved`, SMBIOS, EDID, `.lnk`, Task XML, PDH GPU instances, `svchost -k`, buffer growth |
| `src/system_windows.odin` | Priority classes, elevation check, verified process handle open, process safety checks, UTF-16 helpers, dynamic DLL loaders |
| `src/processes_windows.odin` | Single `NtQuerySystemInformation(SystemProcessInformation)` call into a reused growing buffer; one-time cached `proc_facts` per `(pid, creation_time)`; SID and `svchost` caches |
| `src/columns_windows.odin` | Windows process table columns and `Proc_Extra` formatting and sorting |
| `src/acts_windows.odin` | Verified-handle End Task, Kill, Suspend/Resume, Priority, Efficiency Mode (EcoQoS), and Affinity |
| `src/menu_windows.odin` | Windows process context menu items (Efficiency Mode, Wait Chain) |
| `src/apps_windows.odin` | Start Menu `.lnk` app catalog and native `.exe`/`.lnk` icon loading via `desktop.file_icon` |
| `src/window_list_windows.odin` | Off-UI-thread `EnumWindows` with `DWMWA_CLOAKED` filter and `SetForegroundWindow` activation |
| `src/machine_windows.odin` | Processor-group-aware `SystemProcessorPerformanceInformation` and its sum, `GlobalMemoryStatusEx`, `GetPerformanceInfo`, `EnumPageFiles`, `GetLogicalProcessorInformationEx`, `CallNtPowerInformation`, IOCTL disks, `GetAdaptersAddresses` + `GetIfTable2` |
| `src/gpu_windows.odin` | DXGI adapter enumeration and VRAM, PDH GPU Engine and GPU Process Memory counters for all vendors, optional `nvml.dll` |
| `src/connections_windows.odin` | `GetExtendedTcpTable` and `GetExtendedUdpTable` (IPv4 and IPv6) with reused growing buffer and cached process start times |
| `src/services_windows.odin`, `src/services_view_windows.odin` | Service Control Manager reader/actions (`advapi32.dll`), `svchost` groups, drivers filter, Pause/Continue, startup types, PPL refusal, Windows Event Log (`wevtapi.dll`) pane and detached window |
| `src/startup_windows.odin`, `src/startup_view_windows.odin` | `HKCU` Run, `HKLM` Run (64-bit and 32-bit), User/Common Startup folders, Task Scheduler logon XML tasks, `StartupApproved` binary toggle |
| `src/props_windows.odin`, `src/props_view_windows.odin` | General, History, Security & Resources (integrity, elevation, PPL, critical, privileges, GDI/USER), Threads & Wait Chain Traversal, safe Handles, Modules (64-bit + WOW64), Environment (PEB64 + PEB32) |
| `src/information_windows.odin`, `src/information_view_windows.odin` | Windows edition/build/elevation, SMBIOS, CPU, Memory/Pagefile, DXGI GPUs, NTFS/ReFS volumes, displays + EDID, batteries + health |
| `src/session_windows.odin` | `dwm.exe` display-server guard in the current session |
| `src/dump_windows.odin` | `MiniDumpWriteDump` (`dbghelp.dll`) on a worker thread using a verified handle |
| `src/commands_windows.odin` | Windows command enum, `COMMANDS` table, palette choices, and dispatch |
| `src/settings_windows.odin` | Windows-specific preferences (`services.filter`, `services.eventlog_level`, `services.eventlog_follow`) |
| `src/demo_windows.odin` | Windows demo data for Services, Startup, Properties, and Information |

## Refused alternatives on Windows

- **WMI / COM WBEM queries**: Refused for processes, disks, services, and hardware because WMI adds hundreds of milliseconds of latency, spawns/wakes `WmiPrvSE.exe`, and fails when the WMI repository is corrupt. Direct NT/Win32 APIs (`NtQuerySystemInformation`, IOCTLs, `GetSystemFirmwareTable`, DXGI, SCM, `wevtapi.dll`) are faster and simpler.
- **Subprocesses (`sc.exe`, `schtasks.exe`, `powershell.exe`, `wmic.exe`, `wevtutil.exe`)**: Refused completely. Subprocesses spawn console hosts, distort process lists, localize output unpredictably, and violate direct-API rules.
- **Per-process `OpenProcess` on every sample**: Refused. One `NtQuerySystemInformation(SystemProcessInformation)` call reads every process's counters in a single kernel transition. `OpenProcess` runs only once per newly-seen `(pid, creation_time)` to cache static facts, or when the user opens Properties or runs an action.
- **Silent UAC self-elevation or hidden helper service**: Refused. Inspecteur runs at the user's privilege level and reports clearly when an action needs an administrator.
- **Kernel driver for hidden handle names or CPU MSR temperatures**: Refused. Installing a signed kernel driver is outside scope. Inspecteur reads every user-mode API available and reports access refusals cleanly via `Read_State`.
- **Editing Task Scheduler tasks via COM `ITaskService` to toggle scheduled tasks**: Deferred/refused for initial scope; Inspecteur reads Task Scheduler logon XML files directly without COM and marks scheduled tasks read-only with a clear status note, while Registry `Run` and Startup Folder items toggle natively via `StartupApproved`.
- **Replacing Windows Task Manager (`Image File Execution Options\taskmgr.exe` Debugger key)**: Refused from the UI because modifying HKLM IFEO requires administrator rights and interferes with system recovery tools if the binary moves.
- **Full ETW kernel trace for per-process network bytes**: Refused because starting an `NT Kernel Logger` ETW session requires Administrator rights and consumes a global kernel trace slot; `GetExtendedTcpTable`/`GetExtendedUdpTable` works for standard users.
