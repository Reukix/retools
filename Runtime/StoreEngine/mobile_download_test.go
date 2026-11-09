package main

import (
	"archive/zip"
	"bytes"
	"errors"
	"github.com/majd/ipatool/v2/pkg/appstore"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
	"io"
	"os"
	"path/filepath"
	"testing"
)

type sinfRecorder struct {
	input appstore.ReplicateSinfInput
	calls int
	err   error
}

func (r *sinfRecorder) ReplicateSinf(input appstore.ReplicateSinfInput) error {
	r.input = input
	r.calls++
	return r.err
}

func TestFinalizingMobileDownloadUsesLicenseIndexes(t *testing.T) {
	store := &sinfRecorder{}
	output, err := finalizeMobileDownload(store, appstore.DownloadOutput{DestinationPath: "test.ipa", Sinfs: []appstore.Sinf{{ID: 1, Data: []byte("extension")}, {ID: 0, Data: []byte("main")}}})
	if err != nil || output != "test.ipa" || store.calls != 1 || store.input.Sinfs[0].ID != 0 || store.input.Sinfs[1].ID != 1 {
		t.Fatalf("indexed licenses were not merged: %v", err)
	}
}
func TestMobileDownloadDoesNotPublishIncompleteLicenses(t *testing.T) {
	for _, licenses := range [][]appstore.Sinf{nil, {{ID: 0}}, {{ID: 1, Data: []byte("gap")}}, {{ID: 0, Data: []byte("a")}, {ID: 0, Data: []byte("duplicate")}}} {
		store := &sinfRecorder{}
		output, err := finalizeMobileDownload(store, appstore.DownloadOutput{DestinationPath: "test.ipa", Sinfs: licenses})
		if err == nil || output != "" || store.calls != 0 {
			t.Fatal("incomplete license was published")
		}
	}
	store := &sinfRecorder{err: errors.New("disk write failed")}
	output, err := finalizeMobileDownload(store, appstore.DownloadOutput{DestinationPath: "test.ipa", Sinfs: []appstore.Sinf{{ID: 0, Data: []byte("sinf")}}})
	if err == nil || output != "" {
		t.Fatal("failed license write was reported as complete")
	}
}
func TestFinalizedIPAContainsTheOriginalManifestLicense(t *testing.T) {
	path := filepath.Join(t.TempDir(), "test.ipa")
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	for name, content := range map[string]string{
		"Payload/Test.app/Info.plist":             `<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Test</string></dict></plist>`,
		"Payload/Test.app/SC_Info/Manifest.plist": `<plist version="1.0"><dict><key>SinfPaths</key><array><string>SC_Info/Test.sinf</string></array></dict></plist>`,
		"Payload/Test.app/Test":                   "encrypted fixture unchanged",
	} {
		file, err := writer.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = file.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buffer.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	store := appstore.NewAppStore(appstore.Args{OperatingSystem: operatingsystem.New()})
	if _, err := finalizeMobileDownload(store, appstore.DownloadOutput{DestinationPath: path, Sinfs: []appstore.Sinf{{ID: 0, Data: []byte("test-license")}}}); err != nil {
		t.Fatal(err)
	}
	archive, err := zip.OpenReader(path)
	if err != nil {
		t.Fatal(err)
	}
	defer archive.Close()
	found := false
	for _, file := range archive.File {
		if file.Name == "Payload/Test.app/SC_Info/Test.sinf" {
			reader, err := file.Open()
			if err != nil {
				t.Fatal(err)
			}
			data, err := io.ReadAll(reader)
			reader.Close()
			if err != nil || string(data) != "test-license" {
				t.Fatal("manifest license is missing or changed")
			}
			found = true
		}
	}
	if !found {
		t.Fatal("download completion left an IPA without SINF")
	}
}
