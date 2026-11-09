//go:build retools_embedded

package appstore

import (
	"context"
	"errors"
	"io"
	gohttp "net/http"
	"net/http/cookiejar"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/majd/ipatool/v2/pkg/http"
)

type retoolsStorefrontClient struct {
	request func(http.Request) (http.Result[[]byte], error)
}

type retoolsCatalogJar struct{ *cookiejar.Jar }

func (retoolsCatalogJar) Save() error { return nil }

func (c retoolsStorefrontClient) Send(request http.Request) (http.Result[[]byte], error) {
	return c.request(request)
}
func (c retoolsStorefrontClient) Do(*gohttp.Request) (*gohttp.Response, error) {
	return nil, errors.New("unexpected HTTP operation")
}
func (c retoolsStorefrontClient) NewRequest(string, string, io.Reader) (*gohttp.Request, error) {
	return nil, errors.New("unexpected HTTP operation")
}

func TestRetoolsKnownAccountStorefrontDoesNotRequireRetiredEndpoint(t *testing.T) {
	store := NewAppStore(Args{}).(*appstore)
	store.storefrontClient = retoolsStorefrontClient{request: func(request http.Request) (http.Result[[]byte], error) {
		t.Fatalf("known account storefront requested retired service: %s", request.URL)
		return http.Result[[]byte]{}, nil
	}}
	for storefront, expected := range map[string]string{"143441-1,29": "US", "143441,34": "US", "143462": "JP", "143464-2,29": "SG", "143465": "CN"} {
		country, err := store.countryCodeFromStoreFront(storefront)
		if err != nil || country != expected {
			t.Fatalf("%s resolved to %q: %v", storefront, country, err)
		}
	}
}

func TestRetoolsUnknownStorefrontUsesExactIDDiscovery(t *testing.T) {
	store := NewAppStore(Args{}).(*appstore)
	calls := 0
	store.storefrontClient = retoolsStorefrontClient{request: func(request http.Request) (http.Result[[]byte], error) {
		calls++
		if request.URL != storefrontGenreURL || request.Headers["X-Apple-Store-Front"] != "143442-2,29" {
			t.Fatalf("unexpected discovery: %+v", request)
		}
		return http.Result[[]byte]{StatusCode: 200, Data: []byte(`{"storePlatformData":{"genre":{"meta":{"storefront":{"cc":"FR","id":"143442"}}}}}`)}, nil
	}}
	for i := 0; i < 2; i++ {
		country, err := store.countryCodeFromStoreFront("143442-1,29")
		if err != nil || country != "FR" {
			t.Fatalf("targeted storefront discovery failed: %q %v", country, err)
		}
	}
	if calls != 1 {
		t.Fatalf("targeted lookup was not cached: %d", calls)
	}
}

func TestRetoolsDoesNotReplaceAnUnknownAccountRegion(t *testing.T) {
	store := NewAppStore(Args{}).(*appstore)
	store.storefrontClient = retoolsStorefrontClient{request: func(request http.Request) (http.Result[[]byte], error) {
		return http.Result[[]byte]{StatusCode: 200, Data: []byte(`{"storePlatformData":{"genre":{"meta":{"storefront":{"cc":"US","id":"143441"}}}}}`)}, nil
	}}
	if country, err := store.countryCodeFromStoreFront("199999-1,29"); err == nil || country != "" {
		t.Fatalf("accepted another storefront: %q %v", country, err)
	}
}

func TestRetoolsPublicXVersionLookup(t *testing.T) {
	if os.Getenv("RETOOLS_TEST_PUBLIC_CATALOG") != "1" {
		t.Skip("requires public Apple catalog access")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	jar, _ := cookiejar.New(nil)
	store := NewAppStore(Args{Context: ctx, CookieJar: retoolsCatalogJar{jar}}).(*appstore)
	// Public metadata needs no guest machine or Apple account. Exercise the live
	// catalog URL and parser using the bridge's existing direct HTTP executor.
	store.platformClient = http.NewClient[platformVersionLookupResult](http.Args{Context: ctx, Executor: store.authBackend.Client("bag-direct")})
	version, err := store.lookupLatestExternalVersionID(Account{StoreFront: "143441-1,29"}, App{ID: 333903271, BundleID: "com.atebits.Tweetie2"}, PlatformIPhone)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Trim(version, "0123456789") != "" || version == "" {
		t.Fatalf("invalid X version: %q", version)
	}
	t.Logf("public US X iPhone version resolved: %s (no account credentials)", version)
}
