package assets

import (
	"archive/zip"
	"context"
	"fmt"
	"io"
)

const kernelDownloadBlockSize = 1 << 20

// ZIP's deflate reader requests a few KB at a time. Buffer only this member's
// compressed range so each small read does not become a separate HTTP request.
// Reopening through archive/zip preserves its CRC and size checks.
func openBufferedKernelEntry(ctx context.Context, source io.ReaderAt, archiveSize int64, entry *zip.File, progress func(int64, int64)) (io.ReadCloser, error) {
	offset, err := entry.DataOffset()
	if err != nil {
		return nil, err
	}
	reader := &kernelMemberReaderAt{ctx: ctx, source: source, start: offset, end: offset + int64(entry.CompressedSize64), progress: progress}
	archive, err := zip.NewReader(reader, archiveSize)
	if err != nil {
		return nil, err
	}
	for _, candidate := range archive.File {
		if candidate.Name == entry.Name && candidate.Method == entry.Method && candidate.CRC32 == entry.CRC32 && candidate.CompressedSize64 == entry.CompressedSize64 && candidate.UncompressedSize64 == entry.UncompressedSize64 {
			return candidate.Open()
		}
	}
	return nil, fmt.Errorf("buffered kernel archive member changed")
}

type kernelMemberReaderAt struct {
	ctx         context.Context
	source      io.ReaderAt
	start, end  int64
	bufferStart int64
	buffer      []byte
	progress    func(int64, int64)
}

func (r *kernelMemberReaderAt) ReadAt(output []byte, offset int64) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	if len(output) == 0 {
		return 0, nil
	}
	if offset < r.start || offset >= r.end || int64(len(output)) > r.end-offset {
		return r.source.ReadAt(output, offset)
	}
	total := 0
	for total < len(output) {
		if err := r.ctx.Err(); err != nil {
			return total, err
		}
		position := offset + int64(total)
		blockStart := r.start + ((position-r.start)/kernelDownloadBlockSize)*kernelDownloadBlockSize
		if len(r.buffer) == 0 || r.bufferStart != blockStart {
			length := min(int64(kernelDownloadBlockSize), r.end-blockStart)
			r.buffer = make([]byte, int(length))
			count, err := r.source.ReadAt(r.buffer, blockStart)
			if err != nil {
				r.buffer = nil
				return total, err
			}
			if count != len(r.buffer) {
				r.buffer = nil
				return total, io.ErrUnexpectedEOF
			}
			r.bufferStart = blockStart
			if r.progress != nil {
				r.progress(blockStart+length-r.start, r.end-r.start)
			}
		}
		total += copy(output[total:], r.buffer[position-r.bufferStart:])
	}
	return total, nil
}
