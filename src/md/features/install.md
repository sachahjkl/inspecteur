# The install's choices

Inspecteur installs itself with gui_toolkit's setup (`src/setup.odin`, the toolkit's docs/setup.md). Its own boxes are
the parts of the integration that it offers: each box is tied to its part, so with an install there it shows what the
system has, and what is ticked is what Install writes.

## The boxes

- **Inspecteur in the terminal (on the PATH)**, on at first. On Windows the console launcher `inspecteur.com` goes
  with it (the build embeds it), so `inspecteur --status` in cmd or PowerShell gives its output and its exit code.
- **Open Ctrl+Shift+Esc and Task Manager with Inspecteur (in place of Task Manager)**, off at first, on Windows only,
  with "Everyone on this computer": Task Manager is the machine's, so it runs the install for everyone, which is in
  Program Files where only an administrator writes. With "Only me" the box is off and says why. The toolkit's
  `Part.Task_Manager` does the work; its reasons are in gui_toolkit's src/md/features/default-task-manager.md and
  install-scope.md. Linux has no system task manager and no shortcut that the system owns: no box.

The words of the task manager's box are Windows' (`SETUP_TASK_MANAGER_WORDS`, system_windows.odin): Task Manager is a
name of that system.

## A start from Task Manager

Windows starts the Debugger of taskmgr.exe, the install for everyone, with taskmgr's path and options after it.
`main.odin` calls `setup.task_manager_start` before anything else: taskmgr's arguments are taken away, and the start
is the plain one.

- Elevated (an administrator's Ctrl+Shift+Esc: Windows elevates taskmgr.exe with no prompt), Inspecteur is restricted by
  the toolkit (gui_toolkit's src/md/features/elevated-process.md): its Installation and Updates pages say why they do
  nothing, "Open file location", a link or a terminal open nothing, and its title says "(Administrator)".
- A start from Task Manager never offers the install (`Run_Options.from_task_manager`): who presses Ctrl+Shift+Esc wants
  a task manager, not a setup dialog.

Refused: mapping taskmgr's options (`/7 /startup` from the Startup apps' link) to a section. Their numbers are not
documented and change between versions of Windows; a wrong guess opens a section that the person did not ask for.
