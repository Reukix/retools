package appstore

import "github.com/majd/ipatool/v2/internal/sap/assets"

// ConfigureRetoolsCache isolates the on-device engine's public Apple runtime assets.
// The embedding bridge serializes all invocations before setting this directory.
func ConfigureRetoolsCache(root string)              { assets.RetoolsCacheRoot = root }
var retoolsProgressCallback func(string)
func ConfigureRetoolsProgress(callback func(string)) { assets.RetoolsProgress = callback;retoolsProgressCallback=callback }
func retoolsProgress(message string){if retoolsProgressCallback!=nil{retoolsProgressCallback(message)}}
