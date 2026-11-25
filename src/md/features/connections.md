# Connections

`/proc/net/tcp`, `tcp6`, `udp` and `udp6` list the sockets. `Socket_Reader` keeps their descriptors open and reads each
with `lseek(0)` + a read loop (a single `pread(0)` on a multi-page `seq_file` truncates at one kernel page). A socket's
process is the one whose `/proc/<pid>/fd/<n>` links to `socket:[<inode>]`. Only the processes the user can read are
told.

## The cost of the scan

Scanning every process's descriptors is what costs. To keep it low:

- `owners_scan` opens `<pid>/fd` first through a kept `/proc` descriptor. Kernel threads and other users' processes fail
  in one `openat` (`EACCES`) without touching `stat`.
- For processes that hold at least one socket, the reader opens `../stat` relative to the open `fd/` descriptor (pinned
  to the same process) in one read, instead of reading `stat` twice for every pid on the machine.
- A reading whose sockets are all known (an owner, or none at the last scan: another user's, one in TIME_WAIT) skips the
  scan, ten readings in a row at most. When new socket inodes appear before the periodic full scan, an incremental scan
  walks pids in ascending order (preserving lowest-pid ownership for forked shared sockets) and stops as soon as every
  unknown inode is found.
