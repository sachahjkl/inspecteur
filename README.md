<h1 align="center">inspecteur</h1>

<p align="center"><b>The processes of your Linux machine, at a glance.</b></p>

Inspecteur is a system monitor: what runs, what it uses, and a way to end it. It is one small native program, written in
[Odin](https://odin-lang.org) on [gui_toolkit](https://github.com/sachahjkl/gui_toolkit). It reads `/proc` and nothing
else, its window comes up in under 300 ms, and it uses about 1 % of one core while it refreshes its table each second.

![inspecteur's window](docs/screenshots/processes.png)

## Features

- **Processes**: name with the app's icon, PID, user, CPU %, memory, disk read and write rates, threads; read again
  each second.
- **Apps and background processes**: a process that the desktop's menu knows (its desktop entry) is an app; the
  processes under it are in its group. The other processes are background processes.
- **Sort** by any column: click its title; click again to reverse.
- **Filter as you type**: by name, command line or PID, wherever the keyboard is.
- **End task** (Delete) asks a process to end; **Kill** (Shift+Delete) ends it at once, after a confirmation.
- **A row's menu** (right click, Menu key): End task, Kill, Open file location, Copy command line.
- **Totals**: the machine's CPU and memory in the sidebar and in the footer.
- **Themes**: every theme of gui_toolkit, light or dark.

Performance, Services, Startup, Connections and Information are the next sections.

![a group open and the row's menu](docs/screenshots/menu.png)

## Use

| Key | |
|---|---|
| typing | filter |
| Up, Down, Page Up, Page Down, Ctrl+Home, Ctrl+End | move |
| Right, Left, Enter | open or close an app's group |
| Delete | End task (SIGTERM) |
| Shift+Delete | Kill (SIGKILL), after a confirmation |
| Menu, Shift+F10 | the row's menu |
| Ctrl+Tab, Ctrl+Shift+Tab | the next, the previous section |
| Escape | clear the filter |

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
- [Architecture](docs/architecture.md): how the processes are read, grouped and shown, and why.
- [Development](docs/development.md): building, testing, `inspecteurtool`.

## Licence

MIT, see [LICENSE](LICENSE). Icons: [Lucide](https://lucide.dev), ISC, see gui_toolkit's `src/lucide/LICENSE.txt`.
