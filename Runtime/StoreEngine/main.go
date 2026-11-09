package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	"github.com/majd/ipatool/v2/pkg/appstore"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
	"github.com/rs/zerolog"
)

// Only caller-supplied state is used. Never opens the host's account/keychain/cookie files.
type cookieRecord struct {
	URL     string         `json:"url"`
	Cookies []*http.Cookie `json:"cookies"`
}
type sessionState struct {
	Keys    map[string][]byte `json:"keys"`
	Cookies []cookieRecord    `json:"cookies"`
}
type request struct {
	Operation          string       `json:"operation"`
	Root               string       `json:"root"`
	GUID               string       `json:"guid"`
	Email              string       `json:"email"`
	Password           string       `json:"password"`
	Code               string       `json:"code"`
	State              sessionState `json:"state"`
	App                appstore.App `json:"app"`
	Version            string       `json:"version"`
	AcquireFreeLicense bool         `json:"acquireFreeLicense"`
}
type publicAccount struct {
	Email      string `json:"email"`
	Name       string `json:"name"`
	StoreFront string `json:"storeFront"`
}
type response struct {
	OK           bool           `json:"ok"`
	Error        string         `json:"error,omitempty"`
	RequiresCode bool           `json:"requiresCode,omitempty"`
	State        sessionState   `json:"state"`
	Account      *publicAccount `json:"account,omitempty"`
	Path         string         `json:"path,omitempty"`
	Versions     []string       `json:"versions,omitempty"`
}
type memoryKeychain struct{ values map[string][]byte }

func (m *memoryKeychain) Get(key string) ([]byte, error) {
	value, ok := m.values[key]
	if !ok {
		return nil, errors.New("session item not found")
	}
	return value, nil
}
func (m *memoryKeychain) Set(key string, data []byte) error {
	m.values[key] = append([]byte(nil), data...)
	return nil
}
func (m *memoryKeychain) Remove(key string) error { delete(m.values, key); return nil }

type cookies struct {
	http.CookieJar
	records map[string]cookieRecord
}

func (c *cookies) SetCookies(u *url.URL, values []*http.Cookie) {
	c.CookieJar.SetCookies(u, values)
	for _, value := range values {
		domain := strings.TrimPrefix(strings.ToLower(value.Domain), ".")
		host := strings.ToLower(u.Hostname())
		if domain == "" {
			domain = host
		}
		if domain != host && !strings.HasSuffix(host, "."+domain) {
			continue
		}
		path := value.Path
		if !strings.HasPrefix(path, "/") {
			path = u.Path
			if at := strings.LastIndex(path, "/"); at > 0 {
				path = path[:at]
			} else {
				path = "/"
			}
		}
		key := domain + "\x00" + path + "\x00" + value.Name
		delete(c.records, key)
		if value.MaxAge < 0 || (!value.Expires.IsZero() && value.Expires.Before(time.Now())) {
			continue
		}
		copy := *value
		if copy.MaxAge > 0 {
			copy.Expires = time.Now().Add(time.Duration(copy.MaxAge) * time.Second)
			copy.MaxAge = 0
		}
		c.records[key] = cookieRecord{u.String(), []*http.Cookie{&copy}}
	}
}
func (c *cookies) Save() error { return nil }

type identity struct{ guid, root string }

func (m identity) MacAddress() (string, error) {
	if len(m.guid) != 12 {
		return "", errors.New("invalid local Store identity")
	}
	var parts []string
	for i := 0; i < 12; i += 2 {
		parts = append(parts, m.guid[i:i+2])
	}
	return strings.Join(parts, ":"), nil
}
func (m identity) HomeDirectory() string { return m.root }
func (m identity) ReadPassword(int) ([]byte, error) {
	return nil, errors.New("enter credentials in Retools")
}

var requestLock sync.Mutex
var cancellationLock sync.Mutex
var currentCancel context.CancelFunc
var progress atomic.Value

func init() {
	zerolog.SetGlobalLevel(zerolog.Disabled)
	progress.Store("准备就绪")
	debug.SetMemoryLimit(768 << 20)
	debug.SetGCPercent(50)
	appstore.ConfigureRetoolsProgress(func(message string) { progress.Store(message) })
}

func invoke(input request) (out response) {
	if !requestLock.TryLock() {
		out.State = input.State
		out.Error = "另一个商店操作正在进行，请等待完成或取消。"
		return
	}
	defer requestLock.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	cancellationLock.Lock()
	currentCancel = cancel
	cancellationLock.Unlock()
	defer func() {
		cancel()
		cancellationLock.Lock()
		currentCancel = nil
		cancellationLock.Unlock()
		progress.Store("准备就绪")
	}()
	out.State = input.State
	if !filepath.IsAbs(input.Root) || input.Root == "/" {
		out.Error = "invalid Store workspace"
		return
	}
	if err := os.MkdirAll(input.Root, 0700); err != nil {
		out.Error = "cannot create Store workspace"
		return
	}
	appstore.ConfigureRetoolsCache(filepath.Join(input.Root, "AppleAssets"))
	if out.State.Keys == nil {
		out.State.Keys = map[string][]byte{}
	}
	chain := &memoryKeychain{out.State.Keys}
	jar, _ := cookiejar.New(nil)
	cookieStore := &cookies{jar, map[string]cookieRecord{}}
	for _, record := range input.State.Cookies {
		if u, err := url.Parse(record.URL); err == nil && u.Scheme == "https" {
			cookieStore.SetCookies(u, record.Cookies)
		}
	}
	defer func() {
		out.State.Keys = chain.values
		out.State.Cookies = nil
		for _, record := range cookieStore.records {
			out.State.Cookies = append(out.State.Cookies, record)
		}
		if data, ok := chain.values["account"]; ok {
			var account appstore.Account
			if json.Unmarshal(data, &account) == nil {
				// Keep the Store token in Keychain state; do not retain an Apple ID password.
				account.Password = ""
				chain.values["account"], _ = json.Marshal(account)
				out.Account = &publicAccount{account.Email, account.Name, account.StoreFront}
			}
		}
	}()
	store := appstore.NewAppStore(appstore.Args{Context: ctx, Keychain: chain, CookieJar: cookieStore, OperatingSystem: operatingsystem.New(), Machine: identity{input.GUID, input.Root}})
	var err error
	switch input.Operation {
	case "probe":
		progress.Store("正在检查本机商店解释器…")
		err = appstore.ProbeRetoolsInterpreter(ctx)
	case "probeCancellation":
		progress.Store("正在检查解释器取消…")
		err = appstore.ProbeRetoolsCancellation(ctx)
	case "setupCheck":
		progress.Store("正在下载并校验商店组件…")
		err = appstore.Prepare(ctx)
		if err == nil {
			progress.Store("正在验证商店 SAP 握手和请求签名…")
			err = appstore.VerifyRetoolsSAP(store)
		}
	case "deviceAuthCheck":
		progress.Store("正在校验商店组件…")
		err = appstore.Prepare(ctx)
		if err == nil {
			err = appstore.VerifyRetoolsDeviceAuth(ctx, store)
		}
	case "downloadRuntimeCheck":
		err = appstore.Prepare(ctx)
		if err == nil {
			err = appstore.VerifyRetoolsDownloadRuntime(ctx, store)
		}
	case "prepare":
		progress.Store("正在下载并校验商店运行组件…")
		err = appstore.Prepare(ctx)
	case "login":
		if input.Email == "" || input.Password == "" {
			err = errors.New("enter an Apple ID and password")
			break
		}
		progress.Store("正在下载并校验首次使用的商店组件…")
		err = appstore.Prepare(ctx)
		if err != nil {
			break
		}
		progress.Store("正在登录 App Store…")
		_, err = store.Login(appstore.LoginInput{Email: input.Email, Password: input.Password, AuthCode: input.Code})
		out.RequiresCode = errors.Is(err, appstore.ErrAuthCodeRequired)
	case "account":
		_, err = store.AccountInfo()
	case "versions", "download":
		account, e := store.AccountInfo()
		if e != nil {
			err = errors.New("sign in to the App Store first")
			break
		}
		if input.App.ID <= 0 || input.App.BundleID == "" {
			err = errors.New("invalid target application")
			break
		}
		if input.Operation == "versions" {
			progress.Store("正在读取可下载版本…")
			versions, e := store.ListVersions(appstore.ListVersionsInput{Context: ctx, Account: account.Account, App: input.App, Platform: appstore.PlatformIPhone})
			err = e
			out.Versions = versions.ExternalVersionIdentifiers
			break
		}
		progress.Store("正在获取加密安装包和许可…")
		destination := filepath.Join(input.Root, "download-"+fmt.Sprint(input.App.ID)+".ipa")
		downloaded, e := store.Download(appstore.DownloadInput{Context: ctx, Account: account.Account, App: input.App, OutputPath: destination, ExternalVersionID: input.Version, Platform: appstore.PlatformIPhone})
		if errors.Is(e, appstore.ErrLicenseRequired) && input.AcquireFreeLicense && input.App.Price == 0 {
			progress.Store("正在获取免费应用许可…")
			e = store.Purchase(appstore.PurchaseInput{Account: account.Account, App: input.App, Platform: appstore.PlatformIPhone})
			if e == nil {
				downloaded, e = store.Download(appstore.DownloadInput{Context: ctx, Account: account.Account, App: input.App, OutputPath: destination, ExternalVersionID: input.Version, Platform: appstore.PlatformIPhone})
			}
		}
		err = e
		if e == nil {
			progress.Store("正在合并安装包的商店许可…")
			out.Path, err = finalizeMobileDownload(store, downloaded)
		}
	default:
		err = errors.New("unknown Store operation")
	}
	out.OK = err == nil
	if err != nil {
		out.Error = err.Error()
	}
	return
}

//export rt_store_request
func rt_store_request(raw *C.char) (pointer *C.char) {
	var input request
	defer func() {
		if recover() != nil {
			data, _ := json.Marshal(response{Error: "Store engine stopped unexpectedly", State: input.State})
			pointer = C.CString(string(data))
		}
	}()
	text := C.GoString(raw)
	if len(text) > 16<<20 || json.Unmarshal([]byte(text), &input) != nil {
		return C.CString(`{"ok":false,"error":"invalid Store request","state":{"keys":{},"cookies":[]}}`)
	}
	output := invoke(input)
	data, _ := json.Marshal(output)
	return C.CString(string(data))
}

//export rt_store_progress
func rt_store_progress() *C.char { return C.CString(progress.Load().(string)) }

//export rt_store_cancel
func rt_store_cancel() {
	cancellationLock.Lock()
	defer cancellationLock.Unlock()
	if currentCancel != nil {
		currentCancel()
	}
}

//export rt_store_free
func rt_store_free(pointer *C.char) { C.free(unsafe.Pointer(pointer)) }
func main()                         {}
