package appstore

import "github.com/majd/ipatool/v2/internal/sap/assets"

// The legacy availableStoreFronts endpoint now returns HTTP 404. Retools starts
// with the same established account storefront IDs used by its public catalog,
// then uses the existing, ID-checked discovery for any other account storefront.
// Never substitute the phone's locale or a default country for an unknown ID.
func retoolsInitialStorefronts() map[string]string {
	if !assets.RetoolsEmbedded {
		return nil
	}
	return map[string]string{
		"143441": "US", "143443": "DE", "143444": "GB", "143455": "CA",
		"143460": "AU", "143462": "JP", "143463": "HK", "143464": "SG",
		"143465": "CN", "143467": "IN", "143469": "RU", "143470": "TW",
	}
}
