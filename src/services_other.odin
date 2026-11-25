#+build !linux
#+build !windows
package inspecteur

import "base:runtime"
import i18n "gt:i18n"

// The services on a system not supported yet: none, and the list says why.

Service_Bus :: struct {}

service_bus_close :: proc(b: ^Service_Bus) {}

services_read :: proc(b: ^Service_Bus, m: Manager, out: ^[dynamic]Service, a: runtime.Allocator) -> (problem: string) { return i18n.tr(NOT_AVAILABLE) }

service_act :: proc(b: ^Service_Bus, m: Manager, action: Service_Action, name: string) -> (failure: string) { return i18n.tr(NOT_AVAILABLE) }

unit_details_read :: proc(b: ^Service_Bus, d: ^Unit_Details, a: runtime.Allocator) {}
