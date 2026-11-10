<h1 align="center">inspecteur</h1>

<p align="center"><b>The processes of your Linux machine, at a glance.</b></p>

Inspecteur is a system monitor and task manager: what runs, what it uses, which services and sockets it has, what starts
with the session, and a way to end it. It is one small native program, written in [Odin](https://odin-lang.org) on
[gui_toolkit](https://github.com/sachahjkl/gui_toolkit). Its window comes up in about 250 ms, and it uses about 1 % of one
core while it refreshes its table each second.

Inspecteur is not a port, but it is strongly inspired by [TaskSlinger](http://taskslinger.net): a task manager of that
quality is what Linux lacked. Its sections are the same six: Processes, Performance, Services, Startup, Connections and
Information.

![inspecteur's window](docs/screenshots/processes.png)

## Features

- **Processes**: name with the app's icon, PID, user, CPU %, memory, disk read and write rates, threads, and more columns
  on a right click of the header; read again each second.
- **Apps and background processes**: a process that the desktop's menu knows (its desktop entry) is an app; the
  processes under it are in its group. The other processes are background processes.
- **End task** (Delete) asks a process to end; **Kill** (Shift+Delete) ends it at once, after a confirmation.
  **Properties** (Alt+Enter): its threads, open files, modules, environment and priority.
- **Performance**: CPU (overall or per logical processor), memory, disks, network interfaces and GPUs, a minute of
  history each.
- **Services**: systemd's services, the system's or the user's: their state, whether they start by themselves, their
  main process and memory. Start, Stop, Restart, Enable, Disable, over D-Bus; the manager asks polkit for a system
  service, and the footer says what it answered.
- **Startup**: the XDG autostart entries and the user's systemd services that start with the session; turn one on or off,
  open its file's folder.
- **Connections**: every TCP and UDP socket, IPv4 and IPv6, with its process; End task, Kill, Open in Processes.
- **Information**: the system, the processor, the memory, the GPUs, the disks and file systems, the network interfaces,
  the screens and the batteries. **Copy all** copies it as text.
- **Sort** by any column: click its title; click again to reverse. **Filter as you type**, wherever the keyboard is: the
  filter filters the section shown. A cell too narrow for its text shows it whole when the pointer rests on it.
- **Themes**: every theme of gui_toolkit, light or dark.

![a group open and the row's menu](docs/screenshots/menu.png)

| | |
|---|---|
| ![Services](docs/screenshots/services.png) | ![Startup](docs/screenshots/startup.png) |
| ![Connections](docs/screenshots/connections.png) | ![Information](docs/screenshots/information.png) |

## Use

| Key | |
|---|---|
| typing, Ctrl+F | filter the section shown |
| Escape | clear the filter |
| Ctrl+1 to Ctrl+6, Ctrl+Tab, Ctrl+Shift+Tab | show a section, the next, the previous |
| F5 | read the section again now |
| Up, Down, Page Up, Page Down, Ctrl+Home, Ctrl+End | move in a table |
| Menu, Shift+F10, a right click | the row's menu |
| Enter, a double click | the row's default action: open an app's group, Open in Processes, Open file location |

| Section | Keys |
|---|---|
| Processes | Delete End task, Shift+Delete Kill, Alt+Enter Properties, Right and Left open and close a group |
| Services | Ctrl+S Start, Delete Stop, Ctrl+R Restart, Ctrl+E Enable, Ctrl+D Disable, Ctrl+C Copy name, Ctrl+U System or User |
| Startup | Ctrl+E Enable, Ctrl+D Disable, Space toggles, Ctrl+C Copy command |
| Connections | Delete End task, Shift+Delete Kill, Ctrl+C Copy address |
| Information | Ctrl+C Copy all |

CPU % is a share of the whole machine: 100 % is every core busy. Preferences: [docs/configuration.md](docs/configuration.md).

## Build

```sh
git clone --recurse-submodules <this repository> && cd inspecteur
nix develop
./build.sh release      # build/inspecteur
```

Every step of the project is a command of `tools/inspecteurtool`: `build`, `test`, `check`, `live` (the real program in a
headless sway), `shots`, `bench`. See [docs/development.md](docs/development.md).

## Documentation

- [Configuration](docs/configuration.md): every preference.
- [Architecture](docs/architecture.md): how the processes, services, sockets and the rest are read and shown, and why.
- [Development](docs/development.md): building, testing, `inspecteurtool`.

## Licence

MIT, see [LICENSE](LICENSE). Icons: [Lucide](https://lucide.dev), ISC, see gui_toolkit's `src/lucide/LICENSE.txt`.
