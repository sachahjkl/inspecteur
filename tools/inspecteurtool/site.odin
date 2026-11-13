package inspecteurtool

// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release. The steps are the
// toolkit's (gt:site, its `site` command); this file says what this site is: its address, names and colours.
//   inspecteurtool site build <site> <out>      the changelog's pages and the classic ones from <site>, then what a page
//                                           says when it is shared; <out> is what is published
//   inspecteurtool site check [--site folder] [--shot file.png] [--browser program]
//                                           the pages in a real browser, served on this machine
// {{version}} in the home page is the last version: its download link names the file of that release.

import tk_site "gt:site"

// Where the site is published, what it is: the one place that says it.
SITE_META :: tk_site.Meta{
	url         = "https://inspecteur.froment.software/",
	name        = "inspecteur",
	repository  = REPOSITORY,
	tagline     = "A fast native task manager for Linux",
	changes     = CHANGELOG,
	card        = "img/main.png",
	logo        = "img/logo.png",
	logo_file   = "site/img/logo.png",
	theme       = "#0d1620",
	accent      = "#5be7c4",
	author      = "Sacha Froment",
	author_url  = "https://froment.software",
	publisher   = "Froment Software",
	ld_type     = "SoftwareApplication",
	root_domain = false,   // (github.io answers for /robots.txt and /favicon.ico, not the site)
}

SITE_LD := [?][2]string{
	{"applicationCategory", "UtilitiesApplication"},
	{"operatingSystem", "Linux"},
	{"license", "https://opensource.org/license/mit"},
}

// The site as the toolkit's command takes it (its slices live as long as the tool: SITE_LD is a global).
site_project :: proc() -> tk_site.Project_Site {
	m := SITE_META
	m.ld_fields = SITE_LD[:]
	return {meta = m, dir = "site", pages = {version_mark = "{{version}}"}}
}
