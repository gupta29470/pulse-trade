package http

import "net/http"

// Android App Links.
//
// A custom scheme such as `pulsetrade://` is dispatched by Android when it is
// typed into `adb` or tapped in a browser, but chat clients do not hand an
// unknown scheme to the system: Slack opens the tap in its own view and the app
// never sees it. An `https` link does reach the app, once Android has verified
// that this host belongs to the app — and that verification is a file this host
// has to serve, which is the reason it lives here rather than in the app.
//
// Android fetches `/.well-known/assetlinks.json` at install time (and again on
// demand) and compares the fingerprints below with the certificate the installed
// APK was signed with. The debug keystore's fingerprint is listed because that is
// what this project ships; a build signed with a different key needs its own
// SHA-256 added here, or verification fails and the link stays in the browser.
const (
	appLinkPackageName = "com.pulsetrade.pulse_trade_frontend"

	// The debug keystore at ~/.android/debug.keystore, alias androiddebugkey.
	appLinkDebugFingerprint = "D1:DA:98:52:74:DE:04:AD:BD:E9:E5:4E:63:8F:5F:16:5A:05:B9:22:0B:E9:8B:06:06:1B:4A:AF:2F:EC:D6:97"
)

// appLinkTarget names the app a statement applies to.
type appLinkTarget struct {
	Namespace              string   `json:"namespace"`
	PackageName            string   `json:"package_name"`
	SHA256CertFingerprints []string `json:"sha256_cert_fingerprints"`
}

// appLinkStatement is one Digital Asset Links statement.
type appLinkStatement struct {
	Relation []string      `json:"relation"`
	Target   appLinkTarget `json:"target"`
}

// appLinks serves the Digital Asset Links file.
//
// It is served over the API's own host on purpose: one domain then answers both
// for the data and for "this link belongs to the app", and an `https` link to a
// market path opens the screen instead of a browser.
func appLinks(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, []appLinkStatement{{
		Relation: []string{"delegate_permission/common.handle_all_urls"},
		Target: appLinkTarget{
			Namespace:              "android_app",
			PackageName:            appLinkPackageName,
			SHA256CertFingerprints: []string{appLinkDebugFingerprint},
		},
	}})
}
