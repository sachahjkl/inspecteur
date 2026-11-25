#+build !windows
package inspecteur

// Linux and macOS specific preferences (systemd manager and journal).

import config "gt:config"
import i18n "gt:i18n"

OS_PREF_DEFS := [?]config.Def{
	{name = "services.manager", title = i18n.later("Manager"), description = i18n.later("The services the Services section lists: the system's (system) or the user's (user). Its System and User buttons change it."), kind = .String, default = {s = "system"}, choices = {"system", "user"}, choice_labels = {i18n.later("System"), i18n.later("User")}, tags = {"system", "user", "systemd"}},
	{name = "services.widths", description = "The widths of the Services table's columns that were resized, in ems (description=30). Dragging the line before a column's title changes them.", kind = .String, default = {s = ""}, hidden = true},
	{name = "services.order", description = "The order of the Services table's columns, apart by commas (name,state,description). Dragging a column's title sideways changes it.", kind = .String, default = {s = ""}, hidden = true},
	{name = "services.sort", description = "The column the services are sorted by (name, description, state, startup, load, pid, memory), a - before it for the largest (or Z) first. A click on a title changes it.", kind = .String, default = {s = "name"}, hidden = true},
	{name = "services.journal_boot", title = i18n.later("Journal boot"), description = i18n.later("The details' journal shows this boot's entries alone; off: its last entries, from any boot. Alt+B switches it."), kind = .Bool, default = {b = true}},
	{name = "services.journal_level", title = i18n.later("Journal level"), description = i18n.later("The entries of the details' journal shown: all, warnings (and worse), errors (and worse). Alt+L goes through them."), kind = .String, default = {s = "all"}, choices = {"all", "warnings", "errors"}, choice_labels = {i18n.later("All entries"), i18n.later("Warnings and errors"), i18n.later("Errors")}},
	{name = "services.journal_follow", title = i18n.later("Journal follow"), description = i18n.later("Read the details' journal again every 2 seconds while it is shown: new entries come in at the end. Alt+F switches it."), kind = .Bool, default = {b = true}},
}

Settings_Extra :: struct {
	manager:        Manager,
	journal_boot:   bool,
	journal_level:  Journal_Level,
	journal_follow: bool,   // services.journal_follow
}

settings_read_os :: proc(p: ^config.Prefs, s: ^Settings) {
	s.extra.journal_boot = config.bool_of(p, "services.journal_boot")
	for l in Journal_Level { if JOURNAL_LEVEL_KEYS[l] == config.string_of(p, "services.journal_level") { s.extra.journal_level = l } }
	s.extra.journal_follow = config.bool_of(p, "services.journal_follow")
	s.extra.manager = config.string_of(p, "services.manager") == "user" ? .User : .System
}

settings_changed_os :: proc(app: ^App, name: string) {
	if name == "services.manager" { services_switch(app, app.settings.extra.manager) }
}
