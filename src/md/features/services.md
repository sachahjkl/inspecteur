# Services and Startup: systemd over D-Bus

## The bus, not systemctl

The services come from systemd's managers over D-Bus, through the toolkit's own client (`gt:dbus`, no libdbus, no
`systemctl` started): `ListUnits` and `ListUnitFiles`, then `MainPID` and `MemoryCurrent` of each running service, all
asked before any answer is read. Start, Stop and Restart are `StartUnit`, `StopUnit` and `RestartUnit`; Enable and
Disable are `EnableUnitFiles` and `DisableUnitFiles`, then `Reload`, as `systemctl` does.

## Authorization

A system service's change is the manager's to allow: it asks polkit. The call allows interactive authorization
(`interactive` of `dbus.call`), so polkit can ask the user for a password; what it refuses is said in the footer.
Inspecteur never runs `sudo`.

## Startup

The Startup section reads the XDG autostart entries itself (the Desktop Application Autostart Specification) and asks
the user's manager which services the session's targets want (their `Wants` property). An autostart entry of the system
is turned off by the user's copy of it with `Hidden=true`, as the specification says; turned on again, the copy goes
when nothing else changed in it.

## A service's details and journal

- The unit's properties come over the same bus (`LoadUnit`, then `FragmentPath`, `StateChangeTimestamp`,
  `TasksCurrent`, `CPUUsageNSec`, `NRestarts`).
- The journal's last entries come from `journalctl -u <unit> -n 1000 -o json` (`-b`: this boot): the journal's own
  program reads journald's files. They are read on a thread of their own: when another service is selected, and every
  2 s while it is followed.
- A `Journal_View` (journal.odin) holds one service's reading, its list and its search. The details have one; each
  journal on its own (journal_window.odin: the view `journal`, an instance per service) has its own. Their readings are
  posted to the main window; the views' windows are built right after each of its frames, so they show what came.

## Stop and Restart are asked first

The question says when the service runs the desktop or Inspecteur: its main process is the display server or one
Inspecteur runs under, or Inspecteur's own cgroup is under that unit.
