//go:build retools_embedded

package assets

import (
	"crypto/sha256"
	"os"
	"path/filepath"
	"testing"
)

func TestRetoolsResumeRequiresCompletedVerifiedPublicAsset(t *testing.T) {
	data := []byte("public test asset")
	name := "RetoolsResumeTestAsset-" + filepath.Base(t.TempDir())
	spec := fileSpec{name: name, size: len(data), digest: sha256.Sum256(data)}
	previous := requiredFiles
	requiredFiles = []fileSpec{spec}
	defer func() { requiredFiles = previous }()
	legacy, err := os.MkdirTemp("", "ipatool-macos-27-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(legacy)
	source := filepath.Join(legacy, "frameworks", name)
	if err = os.MkdirAll(filepath.Dir(source), 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(source, data, 0600); err != nil {
		t.Fatal(err)
	}
	destination := t.TempDir()
	if !retoolsExistingAsset(destination, name) {
		t.Fatal("completed public component was downloaded again")
	}
	if !retoolsValidFile(filepath.Join(destination, name), spec) {
		t.Fatal("resumed component was not verified")
	}
	if err = os.WriteFile(source, []byte("incomplete"), 0600); err != nil {
		t.Fatal(err)
	}
	_ = os.Remove(filepath.Join(destination, name))
	if retoolsExistingAsset(destination, name) {
		t.Fatal("incomplete component was accepted")
	}
}
func TestRetoolsDoesNotReadSymlinkedResumeAsset(t *testing.T) {
	data := []byte("test")
	spec := fileSpec{name: "RetoolsSymlinkTestAsset", size: len(data), digest: sha256.Sum256(data)}
	root := t.TempDir()
	file := filepath.Join(root, "file")
	link := filepath.Join(root, "link")
	if err := os.WriteFile(file, data, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(file, link); err != nil {
		t.Fatal(err)
	}
	if retoolsValidFile(link, spec) {
		t.Fatal("symlink must not be reused")
	}
}
func TestRetoolsKeepsAllStoreAuthenticationDependencies(t *testing.T) {
	names := map[string]bool{}
	for _, spec := range requiredFiles {
		names[spec.name] = true
	}
	for _, name := range []string{"CoreFP", "CoreFP.icxs", "commerce", "adid", "AppleMediaServices","fairplayd","FairPlayIOKit"} {
		if !names[name] {
			t.Fatalf("missing required iOS Store component %s", name)
		}
	}
}
