# Connections

`/proc/net/tcp`, `tcp6`, `udp` and `udp6` list the sockets. A socket's process is the one whose `/proc/<pid>/fd/<n>`
links to `socket:[<inode>]`; its start time is read before and after its descriptors. Only the processes the user may read can be told.

## The cost of the scan

That scan of every descriptor is what costs (a few milliseconds). A reading whose sockets are all known (an owner, or
none at the last scan: another user's, one in TIME_WAIT) skips it, ten readings in a row at most.
