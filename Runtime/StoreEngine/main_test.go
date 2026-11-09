package main

import (
	"encoding/json"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"testing"
)

func TestRejectsWorkspaceRootWithoutTouchingAccountProviders(t *testing.T) {
	result := invoke(request{Operation: "account", Root: "/"})
	if result.OK || result.Error != "invalid Store workspace" {
		t.Fatalf("unexpected result: %v", result.OK)
	}
}

func TestSecondOperationDoesNotWaitBehindAnExistingSession(t *testing.T) {
	requestLock.Lock()
	defer requestLock.Unlock()
	result := invoke(request{Operation: "account", Root: t.TempDir()})
	if result.OK || result.Error != "另一个商店操作正在进行，请等待完成或取消。" {
		t.Fatal("second request did not fail promptly")
	}
}
func TestSessionOutputDoesNotRetainAccountPassword(t *testing.T) {
	state := sessionState{Keys: map[string][]byte{"account": []byte(`{"email":"owner@example.invalid","password":"test-secret","passwordToken":"session-only"}`)}}
	result := invoke(request{Operation: "account", Root: t.TempDir(), GUID: "001122334455", State: state})
	if !result.OK {
		t.Fatal(result.Error)
	}
	encoded, _ := json.Marshal(result)
	if strings.Contains(string(encoded), "test-secret") {
		t.Fatal("password leaked in response")
	}
	var account map[string]any
	if json.Unmarshal(result.State.Keys["account"], &account) != nil || account["password"] != nil {
		t.Fatal("password persisted")
	}
	if result.Account == nil || result.Account.Email != "owner@example.invalid" {
		t.Fatal("missing public account")
	}
}
func TestCookieStatePreservesDomainAndPathAcrossCalls(t *testing.T) {
	jar, _ := cookiejar.New(nil)
	original := &cookies{jar, map[string]cookieRecord{}}
	endpoint, _ := url.Parse("https://auth.example.invalid/login")
	original.SetCookies(endpoint, []*http.Cookie{{Name: "session", Value: "test", Domain: "example.invalid", Path: "/", Secure: true}})
	redirect, _ := url.Parse("https://buy.example.invalid/redirect")
	original.SetCookies(redirect, []*http.Cookie{{Name: "session", Value: "renewed", Domain: "example.invalid", Path: "/", Secure: true}})
	secondJar, _ := cookiejar.New(nil)
	restored := &cookies{secondJar, map[string]cookieRecord{}}
	for _, record := range original.records {
		u, _ := url.Parse(record.URL)
		restored.SetCookies(u, record.Cookies)
	}
	target, _ := url.Parse("https://download.example.invalid/package")
	if len(restored.Cookies(target)) != 1 {
		t.Fatal("cookie scope lost during session persistence")
	}
	if restored.Cookies(target)[0].Value != "renewed" {
		t.Fatal("obsolete cookies replaced a renewed session")
	}
}
