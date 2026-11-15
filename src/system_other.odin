#+build !linux
package inspecteur

// What the window says of a system not supported yet: Linux's words, so that the views read the same until a port
// writes its own (src/md/infrastructure/porting.md).

import "core:fmt"
import i18n "gt:i18n"

PRIORITIES := [?]Priority{
	{i18n.later("High (-10)"), -10}, {i18n.later("Above normal (-5)"), -5}, {i18n.later("Normal (0)"), 0}, {i18n.later("Below normal (5)"), 5}, {i18n.later("Low (10)"), 10}, {i18n.later("Idle (19)"), 19},
}

PRIORITY_COLUMN := i18n.later("Nice")

ADMIN :: "root"

PRIORITY_DENIED := i18n.later("only root may raise a priority, or change another user's process")

priority_text :: proc(nice: i8) -> string { return fmt.tprintf(i18n.tr("nice %d"), nice) }
