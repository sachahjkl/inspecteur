#+build !linux
package inspecteur

import "base:runtime"
import i18n "gt:i18n"

// What starts with the session on a system not supported yet: nothing listed, and the list says why.

Startup_Bus :: struct {}

startup_bus_close :: proc(b: ^Startup_Bus) {}

startup_read :: proc(b: ^Startup_Bus, out: ^[dynamic]Startup_Item, a: runtime.Allocator) -> (problem: string) { return i18n.tr(NOT_AVAILABLE) }

startup_set_enabled :: proc(b: ^Startup_Bus, kind: Startup_Kind, id: string, on: bool) -> (failure: string) { return i18n.tr(NOT_AVAILABLE) }
