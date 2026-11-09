package appstore

import (
	"context"
	"errors"
	"fmt"
	"github.com/majd/ipatool/v2/internal/sap/assets"
	"github.com/majd/ipatool/v2/internal/sap/unicorn"
	"github.com/majd/ipatool/v2/internal/store/emulator"
	"github.com/majd/ipatool/v2/internal/store/profile"
	"github.com/majd/ipatool/v2/internal/storeauth"
	"time"
)

// VerifyRetoolsDeviceAuth provisions an anonymous local device identity. No account or password is sent.
func VerifyRetoolsDeviceAuth(ctx context.Context, client AppStore) error {
	store, ok := client.(*appstore)
	if !ok {
		return errors.New("unsupported Store client")
	}
	previous, _ := store.keychain.Get(anisetteKeychainKey)
	retoolsProgress("正在准备设备认证数据…")
	headers, state, err := storeauth.AnisetteHeaders(ctx, store.authHTTP, previous)
	if err != nil {
		return fmt.Errorf("device authentication: %w", err)
	}
	if headers.Get("X-Apple-I-MD") == "" || headers.Get("X-Apple-I-MD-M") == "" {
		return errors.New("device authentication returned incomplete headers")
	}
	return store.keychain.Set(anisetteKeychainKey, state)
}

// VerifyRetoolsDownloadRuntime exercises the download-only guest routines with
// a synthetic DSID and anonymous device identity. It never requests a package
// or uses an Apple account/token.
func VerifyRetoolsDownloadRuntime(ctx context.Context, client AppStore) error {
	store, ok := client.(*appstore)
	if !ok {
		return errors.New("unsupported Store client")
	}
	mac, err := store.machine.MacAddress()
	if err != nil {
		return err
	}
	guid, hardware, err := machineIdentity(mac)
	if err != nil {
		return err
	}
	bundle, err := assets.Load(ctx)
	if err != nil {
		return err
	}
	prepared, err := profile.Load(ctx)
	if err != nil {
		return err
	}
	retoolsProgress("正在核对下载认证编码…")
	if err := emulator.VerifyRetoolsAMDEncoding(ctx, bundle.AppleMediaServices, prepared); err != nil {
		return err
	}
	retoolsProgress("正在验证下载许可计算组件…")
	blob, err := defaultKBSyncGenerator(ctx, hardware, 1)
	if err != nil {
		return err
	}
	if len(blob) == 0 {
		return errors.New("download runtime produced no test kbsync")
	}
	retoolsProgress("正在验证下载设备认证组件…")
	_, state, err := storeauth.AnisetteHeaders(ctx, store.authHTTP, nil)
	if err != nil {
		return err
	}
	headers, _, err := storeauth.StoreAMDHeaders(ctx, store.authHTTP, state, "https://"+downloadDispatchDomain+entDownloadPath+"?guid="+guid, hardware)
	if err != nil {
		return err
	}
	if len(headers) == 0 {
		return errors.New("download runtime produced no device proof")
	}
	return nil
}

// VerifyRetoolsSAP checks the public setup handshake and action signing without a login.
func VerifyRetoolsSAP(client AppStore) error {
	store, ok := client.(*appstore)
	if !ok {
		return errors.New("unsupported Store client")
	}
	mac, err := store.machine.MacAddress()
	if err != nil {
		return err
	}
	guid, hardware, err := machineIdentity(mac)
	if err != nil {
		return err
	}
	bag, err := store.bag(guid)
	if err != nil {
		return err
	}
	signer, err := store.actionSignerFactory(bag.SAPConfig, hardware)
	if err != nil {
		return fmt.Errorf("SAP setup: %w", err)
	}
	defer signer.Close()
	signature, err := signer.Sign([]byte("Retools public SAP verification"))
	if err != nil {
		return err
	}
	if len(signature) == 0 {
		return errors.New("SAP setup returned an empty signature")
	}
	return nil
}

// ProbeRetoolsInterpreter verifies both ARM64 interpretation and the Go/C hook bridge.
// It uses only builtin test instructions and performs no network/account operation.
func ProbeRetoolsInterpreter(ctx context.Context) error {
	engine, err := unicorn.New(ctx)
	if err != nil {
		return err
	}
	defer engine.Close()
	if err = engine.MemMap(0x10000, 0x1000); err != nil {
		return err
	}
	// mov x0,#42; add x0,x0,#58. Execution stops at the end address.
	if err = engine.MemWrite(0x10000, []byte{0x40, 0x05, 0x80, 0xd2, 0x00, 0xe8, 0x00, 0x91}); err != nil {
		return err
	}
	count := 0
	hook, err := engine.AddCodeHook(0x10000, 0x10007, func(uint64, uint32) { count++ })
	if err != nil {
		return err
	}
	defer hook.Close()
	if err = engine.StartBounded(0x10000, 0x10008, 2*time.Second, 10); err != nil {
		return err
	}
	result, err := engine.RegRead(unicorn.RegX0)
	if err != nil {
		return err
	}
	if result != 100 || count != 2 {
		return errors.New("interpreter or callback verification failed")
	}
	return nil
}

func ProbeRetoolsCancellation(ctx context.Context) error {
	engine, err := unicorn.New(ctx)
	if err != nil {
		return err
	}
	defer engine.Close()
	if err = engine.MemMap(0x10000, 0x1000); err != nil {
		return err
	}
	if err = engine.MemWrite(0x10000, []byte{0, 0, 0, 0x14}); err != nil {
		return err
	}
	return engine.StartBounded(0x10000, 0x10004, 30*time.Second, 0)
}
