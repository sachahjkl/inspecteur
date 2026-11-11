type: Changed

**The sockets are read on their own period** (`connections.refresh_ms`, 3 s by default, in the settings' Connections page), not at each refresh of the processes: a reading goes through every process's open files, and Connections or Mission Control shown cost a core's share each second.
