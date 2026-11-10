package inspecteur

// What the window says of the system that is Linux's own: the priorities offered (nice values), the name of the
// administrator. A port writes its own (docs/architecture.md, "Porting to Windows").

import "core:fmt"

// The priorities offered, as nice values: -20 is served first, 19 last. A user may only lower a process's priority
// (raise its nice) without CAP_SYS_NICE: the others are refused ("Access denied").
PRIORITIES := [?]Priority{
	{"High (-10)", -10}, {"Above normal (-5)", -5}, {"Normal (0)", 0}, {"Below normal (5)", 5}, {"Low (10)", 10}, {"Idle (19)", 19},
}

// The Processes table's title of the priority's column.
PRIORITY_COLUMN :: "Nice"

// Who may act on any process.
ADMIN :: "root"

// Why a priority was refused.
PRIORITY_DENIED :: "only root may raise a priority, or change another user's process"

// A priority as the window says it: "nice 5".
priority_text :: proc(nice: i8) -> string { return fmt.tprintf("nice %d", nice) }
