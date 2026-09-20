package http

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Android opens the app for an https link only after this file proves the host
// belongs to it, so the response shape is the contract: a wrong package name or a
// malformed fingerprint silently leaves every link in the browser.
func TestAppLinksServesTheVerificationFile(t *testing.T) {
	rec := httptest.NewRecorder()
	appLinks(rec, httptest.NewRequest(http.MethodGet, "/.well-known/assetlinks.json", nil))

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("content type = %q, want json", ct)
	}

	var statements []appLinkStatement
	if err := json.Unmarshal(rec.Body.Bytes(), &statements); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(statements) != 1 {
		t.Fatalf("statements = %d, want 1", len(statements))
	}

	statement := statements[0]
	if len(statement.Relation) != 1 ||
		statement.Relation[0] != "delegate_permission/common.handle_all_urls" {
		t.Fatalf("relation = %v", statement.Relation)
	}
	if statement.Target.Namespace != "android_app" ||
		statement.Target.PackageName != appLinkPackageName {
		t.Fatalf("target = %+v", statement.Target)
	}
	if len(statement.Target.SHA256CertFingerprints) == 0 {
		t.Fatal("no fingerprints: Android would never verify the host")
	}
	for _, fingerprint := range statement.Target.SHA256CertFingerprints {
		// 32 bytes printed as hex, colon separated: 31 separators.
		if strings.Count(fingerprint, ":") != 31 {
			t.Fatalf("fingerprint %q is not a colon-separated SHA-256", fingerprint)
		}
	}
}
