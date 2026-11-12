package inspecteur

import "core:testing"

// A service's family by the words of its name, the more particular first; its stem, an instance's and a suffix's off.
@(test)
services_have_their_family :: proc(t: ^testing.T) {
	testing.expect_value(t, service_family("bluetooth.service").theme, "bluetooth")
	testing.expect_value(t, service_family("NetworkManager.service").theme, "network-wired")
	testing.expect_value(t, service_family("systemd-timesyncd.service").theme, "preferences-system-time")
	testing.expect_value(t, service_family("sshd.service").theme, "utilities-terminal")
	testing.expect_value(t, service_family("user@1000.service").theme, "system-users")
	testing.expect_value(t, service_family("something-else.service").glyph, SERVICE_FAMILIES[len(SERVICE_FAMILIES) - 1].glyph)
	testing.expect_value(t, service_stem("getty@tty1.service"), "getty")
	testing.expect_value(t, service_stem("NetworkManager.service"), "NetworkManager")
}
