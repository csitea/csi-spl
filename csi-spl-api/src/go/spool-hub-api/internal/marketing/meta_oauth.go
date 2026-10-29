package marketing

import (
	"net/url"
	"strings"
	"time"
)

// meta_oauth.go is the Meta side of connecting a Facebook Page and its
// Instagram account (spec 090 T033, SPL-4254; spec.md §16.2): the OAuth
// dialog URL and the signed state. The code exchange and the Page list are
// meta_client.go's (T032). The state is the LinkedIn connect's (State,
// signState), keyed from the Meta app secret under its own label, so a
// LinkedIn state never verifies here and nobody without the secret can
// forge one.

// MetaScopes are the permissions the connect asks for when cnf names none
// (marketing.facebook.scopes, meta-app-setup.md step 2).
const MetaScopes = "pages_show_list,pages_read_engagement,pages_manage_posts,instagram_basic,instagram_content_publish"

// MetaDialogBase is the host of Meta's OAuth dialog; Meta.DialogBase points
// it at a fake in tests.
const MetaDialogBase = "https://www.facebook.com"

func (m *Meta) stateKey() []byte {
	return stateKey(m.AppSecret, "spool-marketing-meta-connect-state/v1")
}

// NewState signs st (a fresh nonce is added): "<payload>.<mac>", base64url.
func (m *Meta) NewState(st State) string { return signState(m.stateKey(), st) }

// VerifyState checks s's MAC and expiry at now and returns what it binds.
func (m *Meta) VerifyState(s string, now time.Time) (State, error) {
	return verifyState(m.stateKey(), s, now)
}

func (m *Meta) scopes() string {
	if s := strings.TrimSpace(m.Scopes); s != "" {
		return s
	}
	return MetaScopes
}

// AuthorizeURL is the OAuth dialog the member's browser goes to:
// <dialog host>/<version>/dialog/oauth?client_id&redirect_uri&scope&state.
func (m *Meta) AuthorizeURL(state string) (string, error) {
	v, err := m.version()
	if err != nil {
		return "", err
	}
	q := url.Values{
		"response_type": {"code"},
		"client_id":     {m.AppID},
		"redirect_uri":  {m.RedirectURI},
		"state":         {state},
		"scope":         {m.scopes()},
	}
	return orDefault(m.DialogBase, MetaDialogBase) + "/" + v + "/dialog/oauth?" + q.Encode(), nil
}
