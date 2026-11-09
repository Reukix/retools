//go:build retools_embedded

package appstore

import "errors"

func (t *appstore) Revoke() error {
	accountError := t.keychain.Remove("account")
	t.kbsyncCache.mu.Lock()
	defer t.kbsyncCache.mu.Unlock()
	t.kbsyncCache.entry = kbsyncCacheEntry{}
	return errors.Join(accountError, t.keychain.Remove(kbsyncCacheKey))
}
