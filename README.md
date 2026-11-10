<h1 align="center">inspecteur</h1>

<p align="center"><b>The processes of your Linux machine, at a glance.</b></p>

Inspecteur is a system monitor and task manager: what runs, what it uses, which services and sockets it has, what starts
with the session, and a way to end it. It is one small native program, written in [Odin](https://odin-lang.org) on
[gui_toolkit](https://github.com/sachahjkl/gui_toolkit). Its window comes up in about 270 ms, and it uses about 1 % of one
core while it refreshes its table each second.

Inspecteur is not a port, but it is strongly inspired by [TaskSlinger](http://taskslinger.net): a task manager of that
quality is what Linux lacked. Its sections are the same six: Processes, Performance, Services, Startup, Connections and
Information.

![inspecteur's window](docs/screenshots/processes.png)

## Features

- **Processes**: name with the app's icon, PID, user, CPU %, private memory, disk read and write rates, threads, and more
  columns on a right click of the header (Ctrl+Shift+C): parent, state, priority, resident memory, GPU memory, start time,
  command line, executable. Read again each second.
- **Apps and background processes**: a process that the desktop's menu knows (its desktop entry) is an app; the
  processes under it are in its group. The other processes are background processes.
- **End task** (Delete) asks a process to end; **Kill** (Shift+Delete) ends it at once, after a confirmation; on an
  app's group, Kill ends every process of it. **Suspend or resume** (Ctrl+P), **raise or lower the priority**
  (Ctrl+Up, Ctrl+Down). **Properties** (Alt+Enter, Enter): its threads, open files, modules, environment and priority.
  Inspecteur does not suspend itself, what it runs under, or the desktop's compositor.
- **Performance**: CPU (overall or per logical processor), memory, disks, network interfaces and GPUs, sixty readings
  of history each. A laptop's GPU that sleeps is not woken to be read.
- **Services**: systemd's services, the system's or the user's: their state, whether they start by themselves, their
  main process and memory. Start, Stop, Restart, Enable, Disable, over D-Bus; for a system service the manager asks
  polkit, which can ask for a password, and the footer says what it answered.
- **Startup**: the XDG autostart entries and the user's systemd services that start with the session; turn one on or off,
  open its file's folder.
- **Connections**: every TCP and UDP socket, IPv4 and IPv6, with its process; End task, Kill, Open in Processes.
- **Information**: the system, the processor, the memory, the GPUs, the disks and file systems, the network interfaces,
  the screens and the batteries. **Copy all** copies it as text.
- **Every action has its key**, said in its menu line and its button's tooltip. The **command palette** (Ctrl+K,
  Ctrl+Shift+P) finds any action or section as you type; **F1** lists every key.
- **Sort** by any column: click its title; click again to reverse. **Filter as you type**, wherever the keyboard is: the
  filter filters the section shown. A text too narrow for its place shows it whole when the pointer rests on it.
- **The application menu**: the welcome page (and `inspecteur setup`) puts Inspecteur in the menu with its icon, and an
  action per section on its launcher's right click.
- **Themes**: every theme of gui_toolkit, light or dark (Ctrl+Shift+L).

![a group open and the row's menu](docs/screenshots/menu.png)

| | |
|---|---|
| ![Performance](docs/screenshots/performance_cpu.png) | ![Properties](docs/screenshots/properties.png) |
| ![Services](docs/screenshots/services.png) | ![Startup](docs/screenshots/startup.png) |
| ![Connections](docs/screenshots/connections.png) | ![Information](docs/screenshots/information.png) |
| ![The command palette](docs/screenshots/palette.png) | ![The keys](docs/screenshots/shortcuts.png) |

The pictures show the demo's made-up machine (`inspecteur --demo`), not a real one.

## Use

| Key | |
|---|---|
| typing, Ctrl+F | filter the section shown; Escape clears the filter |
| Ctrl+K, Ctrl+Shift+P | the command palette |
| F1 | every key |
| Ctrl+1 to Ctrl+6, Ctrl+Tab, Ctrl+Shift+Tab | show a section, the next, the previous |
| F5 | read the section again now |
| Up, Down, Page Up, Page Down, Home, End | move in a table (Ctrl+Home, Ctrl+End while the filter has text) |
| Menu, Shift+F10, a right click | the row's menu |
| Enter, a double click | the row's default action: open an app's group or a process's Properties, Open in Processes, Open file location |
| Ctrl+Shift+L | light or dark |
| Ctrl+Shift+I | the welcome page: the application menu, the desktop's task manager |

| Section | Keys |
|---|---|
| Processes | Delete End task, Shift+Delete Kill, Ctrl+P Suspend or resume, Ctrl+Up and Ctrl+Down the priority, Alt+Enter Properties, Ctrl+O Open file location, Ctrl+C Copy command line, Right and Left open and close a group, Ctrl+Shift+C Columns |
| Properties | Ctrl+Tab and Ctrl+Shift+Tab the tabs, Ctrl+P, Delete, Shift+Delete, Ctrl+Up, Ctrl+Down as in Processes, Escape closes |
| Performance | Up and Down the devices, Ctrl+G one graph per logical processor |
| Services | Ctrl+S Start, Delete Stop, Ctrl+R Restart, Ctrl+E Enable, Ctrl+D Disable, Enter Open in Processes, Ctrl+C Copy name, Ctrl+U System or User |
| Startup | Ctrl+E Enable, Ctrl+D Disable, Space toggles, Enter Open file location, Ctrl+C Copy command |
| Connections | Delete End task, Shift+Delete Kill, Enter Open in Processes, Ctrl+C Copy address |
| Information | Ctrl+C Copy all |

CPU % is a share of the whole machine: 100 % is every core busy. Preferences: [docs/configuration.md](docs/configuration.md).

## The desktop's task manager

`inspecteur setup` (or the welcome page) puts Inspecteur in the application menu, with its icon; `inspecteur setup
--uninstall` takes it away. The Nix package brings both itself. To open Inspecteur from the desktop's own "task manager"
entry:

- **shojiwm-win7** opens the program that `SHOJIWM_WIN7_TASK_MANAGER` names: set it to `inspecteur` in the session's
  environment (on NixOS, `environment.sessionVariables.SHOJIWM_WIN7_TASK_MANAGER = "inspecteur";`).
- **Another desktop**: bind Ctrl+Shift+Escape to the command `inspecteur` in its keyboard settings.

## Build

```sh
git clone --recurse-submodules <this repository> && cd inspecteur
nix develop
./build.sh release      # build/inspecteur
```

Every step of the project is a command of `tools/inspecteurtool`: `build`, `test`, `check`, `live` (the real program in a
headless sway), `shots`, `bench`, `logo`, `desktop_files`. See [docs/development.md](docs/development.md).

## Documentation

- [Configuration](docs/configuration.md): every preference.
- [Architecture](docs/architecture.md): how the processes, services, sockets and the rest are read and shown, and why;
  what a port to Windows writes.
- [Development](docs/development.md): building, testing, `inspecteurtool`.

## Licence

MIT, see [LICENSE](LICENSE). Icons: [Lucide](https://lucide.dev), ISC, see gui_toolkit's `src/lucide/LICENSE.txt`.
