package emulator

import (
	"context"
	"errors"
	storeprofile "github.com/majd/ipatool/v2/internal/store/profile"
)

// VerifyRetoolsAMDEncoding runs the pinned AMS header assembler with fixed local
// test bytes in place of ADI output. No generated proof leaves this diagnostic.
func VerifyRetoolsAMDEncoding(ctx context.Context, image []byte, prepared storeprofile.Data) error {
	r, err := Open(ctx, image, prepared)
	if err != nil {
		return err
	}
	defer r.Close()
	const otpEntry = uint64(0x1a2c0cc2c)
	if err := r.MemWrite(otpEntry, []byte{0xc0, 0x03, 0x5f, 0xd6}); err != nil {
		return err
	}
	called := false
	r.callbacks[otpEntry] = func() {
		if r.arg(0) != ^uint64(0) {
			panic("AMS type 2 did not request device DSID")
		}
		called = true
		mid, otp := r.alloc(3), r.alloc(3)
		if err := r.MemWrite(mid, []byte{1, 2, 3}); err != nil {
			panic(err)
		}
		if err := r.MemWrite(otp, []byte{4, 5, 6}); err != nil {
			panic(err)
		}
		r.write64(r.arg(1), mid)
		r.write32(r.arg(2), 3)
		r.write64(r.arg(3), otp)
		r.write32(r.arg(4), 3)
		r.set(0)
	}
	headers, err := r.StoreAMDHeaders("https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download?guid=001122334455", []byte{0, 0x11, 0x22, 0x33, 0x44, 0x55}, nil)
	if err != nil {
		return err
	}
	if !called || headers["X-Apple-AMD-M"] != "AQID" || headers["X-Apple-AMD"] != "BAUG" {
		return errors.New("pinned AMS device proof encoding differs from direct ADI")
	}
	return nil
}
