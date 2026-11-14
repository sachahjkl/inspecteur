# Apps (apps.odin, processes.odin)

## What an app is

Wayland does not let a program see the other programs' windows. So an app is what the desktop's menu knows: a desktop
entry under `applications/` of each XDG data folder (not hidden, not run in a terminal).

## How a process finds its app

1. By its name or its executable's name (the entry's program, its id, its window class).
2. An interpreter's process by its script.
3. Else by the systemd unit its launcher made (`app-<launcher>-<desktop id>-<random>.scope`; a `-` of the id is escaped
   `\x2d`).

An entry's program is found past its launchers (`env`, `sudo`, `flatpak run`, `systemd-run`, `uwsm app` and the like:
`program_of`). An interpreter's program (Python, Perl, Ruby, Node, Java, Electron, Wine, a shell) is the script it runs:
`python3`, `bash` or `sh` would make every Python program or shell that app.

## Groups

- A group is one entry: every process of that app and the processes under it, unless one of them is another app (a
  browser started from a terminal is the browser's). Two windows of one app are one group.
- End task on a group asks each of the app's processes to end (`group_roots`): the processes under them end with them,
  as when the app's windows are closed. Kill on a group ends every process of it.

The app's icon is its entry's, from the user's icon theme (`desktop.theme_icon`), made into a texture the first time it
is shown.
