#+build !linux
#+build !windows
package inspecteur

// The session on a system not supported yet: no display server known, no unit.

own_units :: proc() -> []string { return nil }

display_server_pid :: proc() -> i32 { return 0 }
