# The processes

On Linux everything comes from `/proc`, read with system calls (`openat`, `read`, `getdents`) into one buffer. Kernel
threads (`PF_KTHREAD`) are not shown.

## What is read, and when

- **Each sample**: `/proc/stat` (the machine's CPU time), `/proc/meminfo`, the list of pids, then for each process
  `stat` (parent, CPU time, threads, state, nice, start time), `statm` (resident and shared pages) and `io` (bytes read
  from and written to the storage).
- **Once per process**: its command line, its executable, its owner, its systemd unit (`cgroup`), its app.
- **Identity**: a process is the pair (pid, start time). A pid used again is a new process. The table's selection and
  marks are kept by this identity across samples, sorts and filters.

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
- End process tree uses the last sample's parents. With rows marked, End task and Kill act on all of them; the
  confirmation lists each process by its name and PID.
- **A dump file** is gdb's `gcore` of the process, written into `$XDG_CACHE_HOME/inspecteur/dumps`, asked first: it
  holds whatever the process had in memory. Without gcore, or when `kernel.yama.ptrace_scope` refuses, the footer says
  so.

## Properties (props.odin)

The dialog reads only the tab shown: when it opens, when another tab is shown, and every 3 seconds while the process
lives. A reading opens the process's `/proc/<pid>` folder once, checks the start time through it, and reads every file
relative to it: a pid given to another process meanwhile reads nothing. Once the process is gone it reads nothing and
says so.
