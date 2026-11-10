// What inspecteur is to the toolkit's update package (gt:update, its docs/update.md): its name in the manifests and the
// release's file names, what its signatures cover, and the public half of its update key (inspecteurtool update keygen;
// the private half is in secrets/production.yaml and the release workflow's secret UPDATE_SIGNING_KEY). The program
// checks with it (updates.odin), inspecteurtool signs with it (inspecteurtool package).
package inspecteur_update

import update "gt:update"

PRODUCT :: update.Product{
	name         = "inspecteur",
	sign_context = "inspecteur-update-v1\n",
	public_key   = "N_-Hzrm7r1kq6BmNS_2X1rBYgUu8r_QLUT-xocmKrfk",
}
