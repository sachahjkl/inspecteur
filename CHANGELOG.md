# Changelog

All notable changes to inspecteur are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the versions follow [semantic versioning](https://semver.org/).

## [Unreleased]

### Added
- **Processes**: name with the app's icon, PID, user, CPU % (of the whole machine), memory, disk read and write rates,
  threads, read from `/proc` each second (`processes.refresh_ms`).
- **Apps and background processes**: a process the desktop's menu knows is an app; the processes under it are in its
  group, which opens and closes. Two windows of one app are one group.
- **Sort** by any column, **filter** as you type (name, command line, PID).
- **End task** (Delete, SIGTERM) and **Kill** (Shift+Delete, SIGKILL, after a confirmation), from the toolbar, the keys
  or the row's menu; the menu also opens the executable's folder and copies the command line.
- The machine's CPU and memory in the sidebar and the footer.
- The sections Performance, Services, Startup, Connections and Information, to come.
- Preferences: refresh period, theme, light or dark, finish, text size, window size (`docs/configuration.md`).
