package inspecteurtool

// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release. The steps are the
// toolkit's (gt:site, its `site` command); this file says what this site is: its address, names and colours.
//   inspecteurtool site build <site> <out>      the changelog's pages and the classic ones from <site>, then what a page
//                                           says when it is shared; <out> is what is published
//   inspecteurtool site check [--site folder] [--shot file.png] [--browser program]
//                                           the pages in a real browser, served on this machine
// {{version}} in the home page is the last version: its download link names the file of that release. The shop's pages
// (shop) are made with the others (Meta.shop).

import tk_site "gt:site"
import toolbox "gt:toolbox"
import inspecteur_licence "../../src/licence"

// The home page's downloads: Linux and Windows.
@(rodata)
SITE_DOWNLOADS := [?]tk_site.Download{
	{os = "linux", label = "Linux", href = "https://github.com/sachahjkl/inspecteur/releases/download/v{{version}}/inspecteur-{{version}}-linux-x64.tar.gz", detail = "v{{version}} · x64 · .tar.gz · Wayland"},
	{os = "windows", label = "Windows", href = "https://github.com/sachahjkl/inspecteur/releases/download/v{{version}}/inspecteur-{{version}}-windows-x64.zip", detail = "v{{version}} · Windows 10 / 11 · x64 · .zip"},
}

SITE_LD := [?][2]string{
	{"applicationCategory", "UtilitiesApplication"},
	{"operatingSystem", "Linux, Windows"},
	{"license", "https://opensource.org/license/mit"},
}

// The site as the toolkit's command takes it (its slices live as long as the tool: SITE_LD and SITE_DOWNLOADS are globals).
site_project :: proc() -> tk_site.Project_Site {
	// (where the site is published, what it is: the one place that says it; the vendor's fields are the toolkit's)
	m := tk_site.meta_default("Inspecteur", "https://inspecteur.froment.software/", REPOSITORY, "What runs on your computer: processes, performance, services, startup and connections", "#0d1620", "#5be7c4")
	m.ld_fields = SITE_LD[:]
	m.shop = shop()
	return {meta = m, dir = "site", pages = {version_mark = "{{version}}", downloads = SITE_DOWNLOADS[:]}, images = tk_site.images_default()}
}

// The shop: inspecteur's licence (src/licence), sold through Paddle by the toolkit's licence Worker. Its pages (pricing,
// thanks, terms, refunds, privacy, imprint) are the toolkit's templates, filled at each `site build` (Meta.shop). What is empty is
// the maintainer's to give once the shop is set up (gui_toolkit docs/licence.md, "What the maintainer does at the end"):
// until the client token, the price id and the Worker are there, the button says "Coming soon".

shop :: proc() -> tk_site.Shop {
	return {
		name           = "Inspecteur",
		icon           = "../img/logo.png",
		product_title  = "Inspecteur User License",
		price          = "15&nbsp;&euro;",
		price_note     = "",
		environment    = "production",
		client_token   = "live_65ec2d26698921b7c4a38413fb6",   // Paddle's client-side token (public: it is in the page)
		edition        = "supporter",
		price_id       = "pri_01m7fyapvwx2x8qa5m20sbxyjf",   // what `inspecteurtool paddle -apply` printed
		worker         = "https://inspecteur-licence.sacha-42a.workers.dev",
		thanks         = "https://inspecteur.froment.software/thanks/",
		help           = REPOSITORY + "/issues/new",
		register       = "Open Inspecteur's settings (Ctrl+,), the <strong>General</strong> page, <strong>Licence</strong>: paste the key, or choose the file.",
		extension      = inspecteur_licence.PRODUCT.file_extension,
		repository     = REPOSITORY,
		seller         = tk_site.SELLER_FROMENT,
		code_licence   = "MIT License",
		platform       = "Linux (Wayland) and Windows 10 / 11, x64.",
		network        = tk_site.NETWORK_UPDATES_ONLY,
		stylesheet     = "../style.css",
		home           = "../",
		updated        = "2026-11-13",
	}
}

// The site's command: the toolkit's, the shop's pages among the others (Meta.shop).
site_command :: proc() -> toolbox.Command {
	return tk_site.command(site_project())
}
