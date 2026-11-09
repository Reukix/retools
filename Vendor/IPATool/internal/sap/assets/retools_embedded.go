//go:build retools_embedded

package assets

func init() {
	RetoolsEmbedded = true
	// Store AMD/ADI authentication also uses fairplayd and FairPlayIOKit.
	// Keep these dependencies even though the host only downloads iOS packages.
}
