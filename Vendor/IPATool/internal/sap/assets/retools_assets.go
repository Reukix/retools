package assets

import (
	"crypto/sha256"
	"io"
	"os"
	"path/filepath"
	"sync"
)

var RetoolsProgress func(string)
var RetoolsEmbedded bool
var retainedMu sync.Mutex
var retainedBundle *Bundle

func retoolsCachedBundle() (Bundle, bool) {
	retainedMu.Lock()
	defer retainedMu.Unlock()
	if RetoolsEmbedded && retainedBundle != nil {
		return *retainedBundle, true
	}
	return Bundle{}, false
}
func retoolsRetainBundle(bundle Bundle) {
	if !RetoolsEmbedded {
		return
	}
	retainedMu.Lock()
	defer retainedMu.Unlock()
	retainedBundle = &bundle
}
func retoolsProgress(message string) {
	if RetoolsProgress != nil {
		RetoolsProgress(message)
	}
}
func retoolsPartialDirectory() (string, error) {
	directory, err := cacheDirectory()
	if err != nil {
		return "", err
	}
	directory = filepath.Join(directory, "Partial")
	return directory, os.MkdirAll(directory, 0700)
}
func retoolsValidFile(path string, spec fileSpec) bool {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != int64(spec.size) {
		return false
	}
	file, err := os.Open(path)
	if err != nil {
		return false
	}
	defer file.Close()
	hash := sha256.New()
	if _, err = io.Copy(hash, file); err != nil {
		return false
	}
	var digest [32]byte
	copy(digest[:], hash.Sum(nil))
	return digest == spec.digest
}
func retoolsExistingAsset(directory, name string) bool {
	if !RetoolsEmbedded {
		return false
	}
	var spec fileSpec
	found := false
	for _, candidate := range requiredFiles {
		if candidate.name == name {
			spec = candidate
			found = true
			break
		}
	}
	if !found {
		return false
	}
	target := filepath.Join(directory, name)
	if retoolsValidFile(target, spec) {
		retoolsProgress("已复用并校验组件：" + name)
		return true
	}
	// Only this app's own previous public-asset staging directories are examined.
	candidates, _ := filepath.Glob(filepath.Join(os.TempDir(), "ipatool-macos-27-*", "frameworks", name))
	for _, candidate := range candidates {
		if !retoolsValidFile(candidate, spec) {
			continue
		}
		_ = os.Remove(target)
		if os.Link(candidate, target) == nil {
			retoolsProgress("已复用并校验组件：" + name)
			return true
		}
		if retoolsCopyVerified(candidate, target, spec) {
			retoolsProgress("已复用并校验组件：" + name)
			return true
		}
	}
	_ = os.Remove(target)
	return false
}

func retoolsCopyVerified(source, target string, spec fileSpec) bool {
	input, err := os.Open(source)
	if err != nil {
		return false
	}
	defer input.Close()
	output, err := os.CreateTemp(filepath.Dir(target), ".resume-*")
	if err != nil {
		return false
	}
	temporary := output.Name()
	defer os.Remove(temporary)
	count, copyError := io.Copy(output, io.LimitReader(input, int64(spec.size)+1))
	closeError := output.Close()
	if copyError != nil || closeError != nil || count != int64(spec.size) || !retoolsValidFile(temporary, spec) {
		return false
	}
	return os.Rename(temporary, target) == nil
}
