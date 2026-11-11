# changelog.d

One file per change a user can see, assembled into `CHANGELOG.md` when a version is published (`inspecteurtool ship`).
A change adds its fragment here and never edits `CHANGELOG.md` nor `APP_VERSION`: two branches never conflict on them.
A change with no effect a user can see has no fragment.

A fragment is `changelog.d/<yyyyMMdd-HHmmss>-<subject>.md` (subject: lowercase letters, digits and `-`):

```
type: Added

**A short bold summary**: what changed for the user, not how the code changed.
```

`type` is `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed` or `Security`. The text is one entry of the list; it may
span lines, with no blank line and no heading.

`inspecteurtool changelog new <type> <subject> <text>` writes one; `changelog check` (run by `check`) says whether they
are all well formed; `changelog preview` prints what the next version brings. The format is gui_toolkit's
(`gt:changelog`, its docs/changelog.md).
