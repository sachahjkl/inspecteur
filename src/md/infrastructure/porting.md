# The system and the views; porting to Windows

## The rule

Every reading of the system is in a `*_linux.odin` file (Odin builds them on Linux only), behind plain structs and procs
whose names would mean the same on another system. The other files (the models, the views, the commands) hold no path
of `/proc` or `/sys`, no system call: they read the structs and call those procs. The table of each section's model,
reader and view is in [docs/architecture.md](../../../docs/architecture.md).

## Counters, not rates

A reader gives counters, not rates: a process's CPU time since it started, a disk's bytes since boot. The neutral side
makes the rates (`rate_of`, `busy_percent`), the CPU % and the graphs' points, and keeps what it learnt of each process
and device. So the arithmetic is the same on every system, and its tests need no system.

## The demo is a third source

The demo (`demo.odin`, `inspecteur --demo`) is a third source behind the same procs: made-up processes, devices,
services, sockets and details. The pictures of the documentation are made with it, so they hold no data of the machine.
Each new reader has its demo's counterpart.

## Porting to Windows

A port writes `*_windows.odin` files beside the `*_linux.odin` ones, with the same procs and the same structs filled. No
view, model or command changes. What each file gives:

| File | Procs | Fills |
|---|---|---|
| `processes_windows.odin` | `Proc_Reader`, `proc_reader_init`, `proc_reader_destroy`, `procs_read`, `proc_facts`, `proc_state_now` | `Proc_Counters` (pid, parent, a start time that with the pid names the process, CPU time in ns, threads, state, priority as a nice value, resident and private bytes, disk bytes read and written) and `Proc_Facts` (name, command line, executable, owner, the launcher's unit (`""`), when it started) |
| `apps_windows.odin` | `catalog_load` | the `Catalog`'s entries (`catalog_add_entry`): the Start menu's apps, their names and icons |
| `machine_windows.odin` | `Machine_Reader`, `machine_reader_init`, `machine_reader_destroy`, `machine_read`, `cpu_info_read`, `cpu_mhz_now`, `disks_list`, `nets_list` | `Machine_Counters` (each processor's total and idle time in ns, boot time, uptime, handles, `Mem_Fields`, each disk's bytes and busy ms, each interface's bytes), `Cpu_Info`, `Disk_Info`, `Net_Info` |
| `gpu_windows.odin` | `Gpu_Reader`, `gpu_reader_close`, `gpu_read` | `Gpu_Snapshot`: each GPU's `Gpu_Read`, and each process's video memory (`gpu_proc_add`) |
| `props_windows.odin` | `proc_cwd`, `proc_threads`, `proc_files`, `proc_modules`, `proc_environment` (each by pid and start time) | `Thread_Row`, `File_Row`, `Module_Row`, the environment's lines; `Read_State` says what was refused |
| `services_windows.odin` | `Service_Bus`, `service_bus_close`, `services_read`, `service_act`, `unit_details_read` | `Service` (the Service Control Manager's services; `Manager.User` lists none), `Unit_Details` (its file, since when, the event log's last lines) |
| `startup_windows.odin` | `Startup_Bus`, `startup_bus_close`, `startup_read`, `startup_set_enabled` | `Startup_Item` (the Run keys and the Startup folder) |
| `connections_windows.odin` | `Socket_Reader`, `socket_reader_destroy`, `sockets_read` | `Socket` (GetExtendedTcpTable, GetExtendedUdpTable: each with its pid) |
| `information_windows.odin` | `info_read` | `Info_Static` |
| `session_windows.odin` | `display_server_pid`, `own_units` | the pid of the process Inspecteur must not suspend besides itself (dwm.exe), or 0; the services Inspecteur runs in (none) |
| `desktop_windows.odin` | `current_desktop`, `task_manager_hint`, `task_manager_bind` | how Windows opens Inspecteur as its task manager (the Task Manager's replacement key) |
| `dump_windows.odin` | `process_dump`, `DUMP_HOW` | a minidump of the process (MiniDumpWriteDump) |
| `system_windows.odin` | `PRIORITIES`, `PRIORITY_COLUMN`, `PRIORITY_DENIED`, `ADMIN`, `priority_text` | the priority classes offered, as nice values (Idle 19 ... High -10), "an administrator" |

What the toolkit does is already portable: signals, priorities and affinities (`process.signal_process`,
`process.set_priority`, `process.set_affinity`: a Windows port of the toolkit maps End task to WM_CLOSE, Kill to
TerminateProcess), the desktop entry (`gt:desktop`: the Start menu's shortcut), the clipboard, the file manager, a web
page. In the neutral files a priority is a nice value (-20 the highest, 19 the lowest): `system_<os>.odin` gives the
priorities offered and their words; a state is `Proc_State`.
