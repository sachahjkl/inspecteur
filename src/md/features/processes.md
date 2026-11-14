# The processes

On Linux everything comes from `/proc`, read with system calls (`openat`, `read`, `getdents`) into one buffer. Kernel
threads (`PF_KTHREAD`) are not shown.

## What is read, and when

- **Each sample**: `/proc/stat` (the machine's CPU time), `/proc/meminfo`, the list of pids, then for each process
  `stat` (parent, CPU time, threads, state, nice, start time), `statm` (resident and shared pages) and `io` (bytes read
  from and written to the storage).
- **Once per process**: its command line, its executable, its owner, its systemd unit (`cgroup`), its app.
- **Identity**: a process is the pair (pid, start time). A pid used again is a new process. The table's selection (the
  toolkit's `Item_Selection`: the rows selected and the cursor) is kept by this identity across samples, sorts and
  filters.

## Decisions on the numbers

- **CPU %** is the process's CPU time over the machine's, both since the last sample. It is a share of the whole machine
  (top's Irix mode off, as Windows' Task Manager): 100 % is every core busy.
- **Memory** is a process's private memory: its resident pages less those it shares (a file's, shared memory), what it
  costs on its own. A group sums its processes' private memory; their resident memory would count each shared library
  once per process. The Resident column and the Properties show the resident memory too.
- **Disk** is `read_bytes` and `write_bytes` of `io`: what reached the storage, per second. Another user's `io` cannot
  be read: its cells show a dash, and it is not asked again while that process lives.
- **Memory pages**: the page size is the kernel's (`AT_PAGESZ` of `/proc/self/auxv`), not a constant: arm64 may have 16
  or 64 KB pages.
- **Users**: `/etc/passwd` is read again once for a uid it does not have; a uid with no name is shown as its number.
- **Names**: the kernel cuts a command name to 15 bytes; the first argument or the executable gives it whole. A Nix
  wrapper's `.firefox-wrapped` is shown as `firefox`.
- **The tree** (`processes.view = tree`): a filter shows the processes it finds and their lines of parents.

## Acts on a process (menu.odin, acts.odin)

- **A pid freed and given again is never signalled.** The toolkit's `process.signal_process` pins the pid with a pidfd,
  reads the process's start time again, and signals through the pidfd only when it is the same, even between the check
  and the signal.
- A priority and an affinity are set through a descriptor of the process's own `/proc/<pid>` folder, whose start time is
  checked, on every thread of the process; the pidfd says afterwards whether the process still ran.
- **What cannot be undone from the window is refused or asked.** Inspecteur does not suspend itself, the processes it
  runs under (its line of parents), or the display server (on Wayland the compositor, the peer of `$WAYLAND_DISPLAY`'s
  socket: `SO_PEERCRED`): nothing could resume them from its window. Ending the display server, Inspecteur or what it
  runs under is asked first. Enter cancels the question of a kill.
- Suspend or resume reads the process's state at that moment, not the last sample's.
- End process tree uses the last sample's parents.

## Several rows (menu.odin, section.odin)

Every table (Processes, Services, Startup, Connections) selects several rows by the toolkit's rules: click, Ctrl+click,
Shift+click, Ctrl+Shift+click, Shift and the moves, Ctrl+A where the list has the keyboard. The rows are selected by
their ids, so a new sample or reading keeps them.

- **What changes something acts on every row selected**: End task, Kill, End process tree and the signals; a service's
  Start, Stop, Restart, Enable, Disable; a startup item's Enable and Disable; a socket's End task and Kill. Copy takes
  every row selected, a line each.
- **One confirmation names the count.** "Kill 3 processes?", "Stop 2 services?" list each one. End task on several rows
  asks too, where it acts at once on one: a row selected by mistake among many is seen before it ends.
- **An action takes the rows it means something for.** Stop on running and stopped services stops the running ones;
  Enable or disable (Space) follows the cursor's item, and the others selected go the same way.
- **What shows one thing stays on the cursor's row**: Properties, Open file location, Go to service, Show its window,
  Affinity, Suspend, the priority, Open in Processes. These read one process; a selection of several would be a guess.
- **With nothing selected, the cursor's row.** A row the program chose (the search's first process, a service gone
  to) is the cursor before the build that selects it: the acts take it.
- **Ctrl alone stays the program's in Processes.** Ctrl+Up and Ctrl+Down are the priority's and Ctrl+Space pauses the
  refresh, so the cursor does not move alone there; Shift and Ctrl+Shift extend.
- **Escape takes several rows back to the cursor's row**, and the next Escape clears the filter: the toolkit's rule
  (`item_selection_escape`, read in `view_keys` because the filter has the keyboard, not the table).
- **A dump file** is gdb's `gcore` of the process, written into `$XDG_CACHE_HOME/inspecteur/dumps`, asked first: it
  holds whatever the process had in memory. Without gcore, or when `kernel.yama.ptrace_scope` refuses, the footer says
  so.

## Properties (props.odin)

The dialog reads only the tab shown: when it opens, when another tab is shown, and every 3 seconds while the process
lives. A reading opens the process's `/proc/<pid>` folder once, checks the start time through it, and reads every file
relative to it: a pid given to another process meanwhile reads nothing. Once the process is gone it reads nothing and
says so.
