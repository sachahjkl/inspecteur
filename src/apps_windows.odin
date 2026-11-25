package inspecteur

// Windows application catalog and native executable icon loading:
// - Walks User and Common Start Menu Programs folders, parses .lnk shortcuts via winapi.decode_lnk,
//   and registers each target executable with its Start Menu display name and executable path as its icon key.
// - icon_load_native extracts the real executable/shortcut icon via gui_toolkit's desktop.file_icon.

import "core:os"
import "core:path/filepath"
import "core:strings"
import desktop "gt:desktop"
import winapi "winapi"

// "C:\\Program Files\\App\\app.exe" is "app.exe".
base_name :: proc(path: string) -> string {
	b := path
	if i := strings.last_index_any(b, "\\/"); i >= 0 { b = b[i + 1:] }
	return unwrapped(b)
}

icon_load_native :: proc(name: string, px: int) -> (desktop.File_Icon, bool) {
	if name == "" { return {}, false }
	return desktop.file_icon(name, false, px)
}

catalog_load :: proc(c: ^Catalog) {
	// User Start Menu first so user-specific shortcuts take precedence over system-wide ones.
	roots := [2]string{
		win_expand_env(`%APPDATA%\Microsoft\Windows\Start Menu\Programs`, context.temp_allocator),
		win_expand_env(`%ProgramData%\Microsoft\Windows\Start Menu\Programs`, context.temp_allocator),
	}
	for r in roots {
		if r == "" || strings.index_byte(r, '%') >= 0 { continue }
		start_menu_walk(c, r, 0)
	}
}

@(private = "file")
START_MENU_DEPTH_MAX :: 4

@(private = "file")
start_menu_walk :: proc(c: ^Catalog, dir: string, depth: int) {
	if depth > START_MENU_DEPTH_MAX { return }
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		full := e.fullpath
		if e.type == .Directory {
			start_menu_walk(c, full, depth + 1)
			continue
		}
		if !strings.has_suffix(strings.to_lower(e.name, context.temp_allocator), ".lnk") { continue }
		raw, rerr := os.read_entire_file(full, context.temp_allocator)
		if rerr != nil { continue }
		lnk, ok := winapi.decode_lnk(raw, context.temp_allocator)
		if !ok || lnk.target == "" { continue }
		target := win_expand_env(lnk.target, context.temp_allocator)
		low_target := strings.to_lower(target, context.temp_allocator)
		if !strings.has_suffix(low_target, ".exe") { continue }
		// Skip uninstallers and generic system hosts so they never hijack real apps.
		base := strings.to_lower(base_name(target), context.temp_allocator)
		if strings.contains(base, "unins") || base == "cmd.exe" || base == "powershell.exe" ||
			base == "pwsh.exe" || base == "rundll32.exe" || base == "msiexec.exe" || base == "explorer.exe" {
			continue
		}
		display := strings.trim_suffix(e.name, filepath.ext(e.name))
		if display == "" { display = base }
		icon_path := lnk.icon != "" ? win_expand_env(lnk.icon, context.temp_allocator) : target
		stem := strings.trim_suffix(base, ".exe")
		catalog_add_entry(c, stem, display, icon_path, base, stem)
	}
}
