#+build !linux
package inspecteur

import i18n "gt:i18n"

// A dump file on a system not supported yet: none is written.

DUMP_HOW := i18n.later("No dump can be written on this system.")

process_dump :: proc(pid: i32, start: u64, name: string) -> (path: string, why: string) { return "", i18n.tr(NOT_AVAILABLE) }
