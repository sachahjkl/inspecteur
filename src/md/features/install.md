# The install's choices

Inspecteur installs itself with gui_toolkit's setup (`src/setup.odin`, the toolkit's docs/setup.md). Its own boxes are
the parts of the integration that it offers: each box is tied to its part, so with an install there it shows what the
system has, and what is ticked is what Install writes.

## The boxes

- **Inspecteur in the terminal (on the PATH)**, on at first. On Windows the console launcher `inspecteur.com` goes
  with it (the build embeds it), so `inspecteur --status` in cmd or PowerShell gives its output and its exit code.
- **Open Ctrl+Shift+Esc and Task Manager with Inspecteur (in place of Task Manager)**, off at first, on Windows only.
  The toolkit's `Part.Task_Manager` does the work; its reasons are in gui_toolkit's
  src/md/features/default-task-manager.md. The box exists only where `desktop.supported_parts()` has the part: Linux
  has no system task manager and no shortcut that the system owns, so it shows no box rather than a part that does
  only half of it.

The words of the task manager's box are Windows' (`SETUP_TASK_MANAGER_WORDS`, system_windows.odin): Task Manager is a
name of that system.

## A start from Task Manager

Windows starts the Debugger of taskmgr.exe, which is Inspecteur's machine copy in Program Files, with taskmgr's path and
options after it. `main.odin` calls `setup.task_manager_start` before anything else:

- The person's own installed copy runs when the start is not elevated: the machine copy ends at once. The installed
  copy gets no argument, so it opens as from its menu (its single instance brings a running window forward).
- Elevated, or for an account with no install, the machine copy runs itself, with taskmgr's arguments taken away.
- The machine copy, when elevated (an administrator's Ctrl+Shift+Esc: Windows elevates taskmgr.exe with no prompt),
  is restricted by the toolkit (gui_toolkit's src/md/features/elevated-process.md): its Installation and Updates pages
  say why they do nothing, "Open file location", a link or a terminal open nothing, and its title says
  "(Administrator)". Unelevated, it has the person's own token and is a plain Inspecteur, which never installs itself
  into their folder.
- A start from Task Manager never offers the install (`Run_Options.from_task_manager`). Another account that
  presses Ctrl+Shift+Esc wants a task manager, not a setup dialog.

Refused: mapping taskmgr's options (`/7 /startup` from the Startup apps' link) to a section. Their numbers are not
documented and change between versions of Windows; a wrong guess opens a section that the person did not ask for.
