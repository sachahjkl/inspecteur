#+build !windows
package inspecteur

// Non-Windows processes keep no extra per-process fields beyond Proc_Counters, Proc_Facts, and Proc.

Proc_Counters_Extra :: struct {}
Proc_Facts_Extra    :: struct {}
Proc_Extra          :: struct {}

proc_learn_extra :: proc(p: ^Proc, c: Proc_Counters, f: Proc_Facts) {}
proc_update_extra :: proc(p: ^Proc, c: Proc_Counters) {}
proc_free_extra :: proc(p: ^Proc) {}
proc_has_service :: proc(p: ^Proc) -> bool { return p.unit != "" }
