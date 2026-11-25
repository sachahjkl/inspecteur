package inspecteur

// Windows-specific preferences (SCM service filter and Windows Event Log pane settings).

import config "gt:config"
import i18n "gt:i18n"

OS_PREF_DEFS := [?]config.Def{
	{name = "services.filter", title = i18n.later("Service filter"), description = i18n.later("Which Windows services the Services section lists: all Win32 services (services), shared svchost services (shared), or drivers (drivers)."), kind = .String, default = {s = "services"}, choices = {"services", "shared", "drivers"}, choice_labels = {i18n.later("Services"), i18n.later("Shared (svchost)"), i18n.later("Drivers")}, tags = {"services", "svchost", "drivers", "scm"}},
	{name = "services.widths", description = "The widths of the Services table's columns that were resized, in ems (account=20). Dragging the line before a column's title changes them.", kind = .String, default = {s = ""}, hidden = true},
	{name = "services.order", description = "The order of the Services table's columns, apart by commas (name,status,account). Dragging a column's title sideways changes it.", kind = .String, default = {s = ""}, hidden = true},
	{name = "services.sort", description = "The column the services are sorted by (name, display_name, status, startup_type, pid, group, account, protection), a - before it for the largest (or Z) first. A click on a title changes it.", kind = .String, default = {s = "name"}, hidden = true},
	{name = "services.eventlog_level", title = i18n.later("Event Log level"), description = i18n.later("The Windows Event Log entries shown in the service details pane: all, warnings (and errors), or errors only. Alt+L cycles them."), kind = .String, default = {s = "all"}, choices = {"all", "warnings", "errors"}, choice_labels = {i18n.later("All entries"), i18n.later("Warnings and errors"), i18n.later("Errors")}},
	{name = "services.eventlog_follow", title = i18n.later("Event Log follow"), description = i18n.later("Read the Windows Event Log again every 3 seconds while the details pane is shown. Alt+F switches it."), kind = .Bool, default = {b = true}},
}

Settings_Extra :: struct {
	service_filter:  Win_Service_Filter,
	eventlog_level:  EventLog_Level,
	eventlog_follow: bool,
}

settings_read_os :: proc(p: ^config.Prefs, s: ^Settings) {
	fval := config.string_of(p, "services.filter")
	s.extra.service_filter = .Services
	for f in Win_Service_Filter { if WIN_SERVICE_FILTER_KEYS[f] == fval { s.extra.service_filter = f } }
	lval := config.string_of(p, "services.eventlog_level")
	s.extra.eventlog_level = .All
	for l in EventLog_Level { if EVENTLOG_LEVEL_KEYS[l] == lval { s.extra.eventlog_level = l } }
	s.extra.eventlog_follow = config.bool_of(p, "services.eventlog_follow")
}

settings_changed_os :: proc(app: ^App, name: string) {
	if name == "services.filter" { services_filter_switch(app, app.settings.extra.service_filter) }
}
