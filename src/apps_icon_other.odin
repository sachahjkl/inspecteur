#+build !windows
package inspecteur

import "core:strings"
import desktop "gt:desktop"

// "/usr/bin/firefox" is "firefox"; a Nix wrapper's ".firefox-wrapped" too. (A '\\' is a letter of a name here.)
base_name :: proc(path: string) -> string {
	b := path
	if i := strings.last_index_byte(b, '/'); i >= 0 { b = b[i + 1:] }
	return unwrapped(b)
}

icon_load_native :: proc(name: string, px: int) -> (desktop.File_Icon, bool) {
	return desktop.theme_icon(name, px)
}
