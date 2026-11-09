package storeauth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"runtime/debug"

	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/sap/machine"
)

// StoreAMDHeaders obtains the device (-1 DSID) ADI output used by AMS type 2.
// The pinned AMS wrapper only base64-encodes these outputs as AMD-M and AMD.
// Calling ADI directly avoids opening a fifth VM and the nil wrapper result.
func StoreAMDHeaders(ctx context.Context, client *http.Client, encoded []byte, endpoint string, hardwareID []byte) (map[string]string, []byte, error) {
	if ctx == nil {
		return nil, nil, errors.New("store AMD context is nil")
	}
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || len(hardwareID) != 6 {
		return nil, nil, errors.New("invalid Store AMD endpoint or hardware identity")
	}

	state, err := decodeAnisetteState(encoded)
	if err != nil {
		return nil, nil, err
	}

	if len(state.Provisioning) == 0 {
		return nil, nil, errors.New("store AMD state is not provisioned")
	}

	bundle, err := assets.Load(ctx)
	if err != nil {
		return nil, nil, fmt.Errorf("load Store AMD assets: %w", err)
	}

	adi, err := machine.OpenModernADI(ctx, bundle, state.Identifier, state.Provisioning)
	if err != nil {
		return nil, nil, fmt.Errorf("open Store AMD service: %w", err)
	}

	defer func() { _ = adi.Close() }()

	mid, otp, err := adi.RequestOTP(storeAnisetteDSID)
	if err != nil {
		var status *machine.ADIOTPError
		if client != nil && errors.As(err, &status) && status.Status == -45061 && ctx.Err() == nil {
			// The saved ADI database alone does not restore the FairPlay session
			// on every runtime. Reprovision an anonymous identity once and consume
			// its fresh device OTP before that live session is closed.
			_ = adi.Close()
			if assets.RetoolsEmbedded {
				debug.FreeOSMemory()
			}
			if assets.RetoolsProgress != nil {
				assets.RetoolsProgress("正在更新商店下载认证…")
			}
			fresh, updated, freshErr := AnisetteHeaders(ctx, client, encoded)
			if freshErr != nil {
				return nil, nil, fmt.Errorf("refresh Store AMD proof: %w", freshErr)
			}
			mid, midErr := base64.StdEncoding.DecodeString(fresh.Get("X-Apple-I-MD-M"))
			otp, otpErr := base64.StdEncoding.DecodeString(fresh.Get("X-Apple-I-MD"))
			if midErr != nil || otpErr != nil {
				return nil, nil, errors.New("invalid refreshed device proof")
			}
			headers, encodingErr := encodeStoreAMD(mid, otp)
			return headers, updated, encodingErr
		}
		return nil, nil, fmt.Errorf("generate Store AMD device proof: %w", err)
	}
	headers, err := encodeStoreAMD(mid, otp)
	if err != nil {
		return nil, nil, err
	}

	state.Provisioning, err = adi.State()
	if err != nil {
		return nil, nil, fmt.Errorf("persist Store AMD state: %w", err)
	}

	updated, err := json.Marshal(state)
	if err != nil {
		return nil, nil, errors.New("encode Store AMD state")
	}

	return headers, updated, nil
}

func encodeStoreAMD(mid, otp []byte) (map[string]string, error) {
	if len(mid) == 0 || len(otp) == 0 || len(mid) > 6144 || len(otp) > 6144 {
		return nil, errors.New("Store AMD returned an invalid device proof")
	}
	return map[string]string{"X-Apple-AMD-M": base64.StdEncoding.EncodeToString(mid), "X-Apple-AMD": base64.StdEncoding.EncodeToString(otp)}, nil
}
