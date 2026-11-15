#+build !linux
package inspecteur

import i18n "gt:i18n"

// Why an action fails on a system that has no reader yet: the portable code shows it as any refusal.
NOT_AVAILABLE := i18n.later("not available on this system")
