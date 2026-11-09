package assets

import (
	"archive/zip"
	"bytes"
	"context"
	"errors"
	"io"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

type countingKernelSource struct {
	*bytes.Reader
	requests int
}

func (s *countingKernelSource) ReadAt(output []byte, offset int64) (int, error) {
	s.requests++
	return s.Reader.ReadAt(output, offset)
}

func kernelTestArchive(t *testing.T, method uint16) ([]byte, []byte, *zip.File) {
	t.Helper()
	payload := make([]byte, 3*kernelDownloadBlockSize+127)
	_, _ = rand.New(rand.NewSource(42)).Read(payload)
	var buffer bytes.Buffer
	writer := zip.NewWriter(&buffer)
	file, err := writer.CreateHeader(&zip.FileHeader{Name: "kernel", Method: method})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = file.Write(payload); err != nil {
		t.Fatal(err)
	}
	if err = writer.Close(); err != nil {
		t.Fatal(err)
	}
	data := buffer.Bytes()
	archive, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	return data, payload, archive.File[0]
}

func TestRetoolsKernelDownloadBuffersNetworkReads(t *testing.T) {
	data, payload, entry := kernelTestArchive(t, zip.Deflate)
	baseline := &countingKernelSource{Reader: bytes.NewReader(data)}
	archive, err := zip.NewReader(baseline, int64(len(data)))
	if err != nil {
		t.Fatal(err)
	}
	original, err := archive.File[0].Open()
	if err != nil {
		t.Fatal(err)
	}
	if _, err = io.Copy(io.Discard, original); err != nil {
		t.Fatal(err)
	}
	_ = original.Close()
	source := &countingKernelSource{Reader: bytes.NewReader(data)}
	var completed int64
	reader, err := openBufferedKernelEntry(context.Background(), source, int64(len(data)), entry, func(done, total int64) {
		if done <= completed || done > total {
			t.Fatalf("invalid progress %d / %d", done, total)
		}
		completed = done
	})
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	result, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(result, payload) {
		t.Fatal("buffered ZIP contents changed")
	}
	if completed != int64(entry.CompressedSize64) {
		t.Fatal("download never reached completion")
	}
	if source.requests > 10 || baseline.requests < source.requests*20 {
		t.Fatalf("network read count: old=%d buffered=%d", baseline.requests, source.requests)
	}
	t.Logf("3 MB member: network reads reduced from %d to %d", baseline.requests, source.requests)
}

func TestRetoolsKernelDownloadPreservesZIPIntegrity(t *testing.T) {
	data, _, entry := kernelTestArchive(t, zip.Store)
	offset, err := entry.DataOffset()
	if err != nil {
		t.Fatal(err)
	}
	data[offset+100] ^= 1
	reader, err := openBufferedKernelEntry(context.Background(), bytes.NewReader(data), int64(len(data)), entry, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	if _, err = io.Copy(io.Discard, reader); !errors.Is(err, zip.ErrChecksum) {
		t.Fatalf("corrupt kernel member accepted: %v", err)
	}
}

func TestRetoolsKernelDownloadCancellation(t *testing.T) {
	data, _, entry := kernelTestArchive(t, zip.Deflate)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	source := &countingKernelSource{Reader: bytes.NewReader(data)}
	reader, err := openBufferedKernelEntry(ctx, source, int64(len(data)), entry, func(_, _ int64) { cancel() })
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	if _, err = io.Copy(io.Discard, reader); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled download continued: %v", err)
	}
	if source.requests > 5 {
		t.Fatalf("requests continued after cancel: %d", source.requests)
	}
}

// Explicit opt-in: downloads only the pinned public Apple kernel member, no account.
func TestRetoolsRemoteFairPlayComponent(t *testing.T) {
	if os.Getenv("RETOOLS_TEST_REMOTE_KERNEL") != "1" {
		t.Skip("public Apple download requires explicit test flag")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	remote, err := openRemoteFile(ctx, &http.Client{Timeout: 45 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	archive, err := zip.NewReader(remote, remote.size)
	if err != nil {
		t.Fatal(err)
	}
	previous := RetoolsProgress
	RetoolsProgress = func(stage string) { t.Log(stage) }
	defer func() { RetoolsProgress = previous }()
	output := filepath.Join(t.TempDir(), "FairPlayIOKit")
	start := time.Now()
	if err := extractFairPlayKext(ctx, archive, remote, output); err != nil {
		t.Fatal(err)
	}
	for _, spec := range requiredFiles {
		if spec.name == "FairPlayIOKit" && !retoolsValidFile(output, spec) {
			t.Fatal("component SHA-256 does not match pinned profile")
		}
	}
	t.Logf("download, extract and SHA-256 verification completed in %s", time.Since(start))
}
