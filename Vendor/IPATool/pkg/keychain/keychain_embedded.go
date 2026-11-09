//go:build retools_embedded

package keychain

// Embedded hosts supply their own Keychain. No desktop keyring provider is linked.
type Keychain interface {
    Get(key string) ([]byte,error)
    Set(key string,data []byte) error
    Remove(key string) error
}
