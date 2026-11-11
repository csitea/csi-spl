package marketing

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

// SPL-5258: the Company Page client (spec 090 T041) against a fake LinkedIn.
// Every token below is an obvious fake.

const testOrgToken = "fake-org-access-not-a-secret"

func fakeLinkedInOrg(t *testing.T, h http.HandlerFunc) *LinkedInOrg {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &LinkedInOrg{ClientID: "org-cid", ClientSecret: NewPlaintext(testSecret), RedirectURI: "https://app.example.com/cb",
		Version: "202610", AuthBase: srv.URL, APIBase: srv.URL, HTTP: srv.Client()}
}

// A state of the personal-profile app never verifies on the Page app, and
// the other way round (domain-separated keys, one client secret).
func TestLinkedInOrgStateDomainSeparated(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	o := &LinkedInOrg{ClientSecret: NewPlaintext(testSecret)}
	l := &LinkedIn{ClientSecret: NewPlaintext(testSecret)}
	st := State{Tenant: "spool", Member: "HUM-1", Exp: now.Add(time.Minute).Unix()}
	if got, err := o.VerifyState(o.NewState(st), now); err != nil || got.Tenant != "spool" || got.Member != "HUM-1" {
		t.Fatalf("own state: %+v %v", got, err)
	}
	if _, err := o.VerifyState(l.NewState(st), now); !errors.Is(err, ErrState) {
		t.Fatalf("a personal state verified on the Page app: %v", err)
	}
	if _, err := l.VerifyState(o.NewState(st), now); !errors.Is(err, ErrState) {
		t.Fatalf("a Page state verified on the personal app: %v", err)
	}
}

func TestLinkedInOrgAuthorizeURL(t *testing.T) {
	o := &LinkedInOrg{ClientID: "org-cid", RedirectURI: "https://app.example.com/cb"}
	u, err := url.Parse(o.AuthorizeURL("st"))
	if err != nil || u.Host != "www.linkedin.com" || u.Path != "/oauth/v2/authorization" {
		t.Fatalf("authorize url %v %v", u, err)
	}
	q := u.Query()
	if q.Get("scope") != "w_organization_social r_organization_social rw_organization_admin" || q.Get("client_id") != "org-cid" ||
		q.Get("state") != "st" || q.Get("response_type") != "code" || q.Get("redirect_uri") != o.RedirectURI {
		t.Fatalf("query %v", q)
	}
	o.Scopes = "r_organization_admin w_organization_social"
	if u, _ := url.Parse(o.AuthorizeURL("st")); u.Query().Get("scope") != o.Scopes {
		t.Fatalf("configured scopes not used: %v", u.Query())
	}
}

func TestLinkedInOrgExchangeAndRefresh(t *testing.T) {
	var forms []url.Values
	o := fakeLinkedInOrg(t, func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		forms = append(forms, r.PostForm)
		if r.URL.Path != "/oauth/v2/accessToken" || r.PostForm.Get("client_secret") != testSecret {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch r.PostForm.Get("grant_type") {
		case "authorization_code":
			_, _ = io.WriteString(w, `{"access_token":"a1-not-a-secret","expires_in":5184000,"refresh_token":"r1-not-a-secret","refresh_token_expires_in":31536000}`)
		case "refresh_token":
			if r.PostForm.Get("refresh_token") != "r1-not-a-secret" {
				w.WriteHeader(http.StatusBadRequest)
				_, _ = io.WriteString(w, `{"error":"invalid_grant","error_description":"The provided refresh token is invalid"}`)
				return
			}
			_, _ = io.WriteString(w, `{"access_token":"a2-not-a-secret","expires_in":5184000}`)
		}
	})
	now := time.Unix(1_800_000_000, 0)
	tok, err := o.Exchange(context.Background(), "code-1", now)
	if err != nil || tok.Access.Reveal() != "a1-not-a-secret" || tok.Refresh.Reveal() != "r1-not-a-secret" ||
		!tok.ExpiresAt.Equal(now.Add(60*24*time.Hour)) || !tok.RefreshExpiresAt.Equal(now.Add(365*24*time.Hour)) {
		t.Fatalf("exchange: %+v %v", tok, err)
	}
	if !tok.ConsentEnd().Equal(tok.RefreshExpiresAt) {
		t.Fatalf("consent end %v, want the refresh end", tok.ConsentEnd())
	}
	if forms[0].Get("code") != "code-1" || forms[0].Get("redirect_uri") != o.RedirectURI || forms[0].Get("client_id") != "org-cid" {
		t.Fatalf("exchange form %v", forms[0])
	}
	later := now.Add(59 * 24 * time.Hour)
	fresh, err := o.Refresh(context.Background(), tok, later)
	if err != nil || fresh.Access.Reveal() != "a2-not-a-secret" || fresh.Refresh.Reveal() != "r1-not-a-secret" ||
		!fresh.RefreshExpiresAt.Equal(tok.RefreshExpiresAt) || !fresh.ExpiresAt.Equal(later.Add(60*24*time.Hour)) {
		t.Fatalf("refresh keeps the refresh token and its first end: %+v %v", fresh, err)
	}
	_, err = o.Refresh(context.Background(), OrgToken{Refresh: NewPlaintext("revoked")}, later)
	if !OrgRefreshRefused(err) || strings.Contains(err.Error(), "revoked") {
		t.Fatalf("a refused refresh: %v, want refused with no token text", err)
	}
	// no refresh token issued (a restricted tier): the access token alone
	noRefresh := OrgToken{Access: NewPlaintext("a"), ExpiresAt: now.Add(time.Hour)}
	if !noRefresh.ConsentEnd().Equal(noRefresh.ExpiresAt) {
		t.Fatal("consent end without a refresh token is not the access token's end")
	}
}

func TestLinkedInOrgAdminPages(t *testing.T) {
	o := fakeLinkedInOrg(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+testOrgToken || r.Header.Get("LinkedIn-Version") != "202610" ||
			r.Header.Get("X-Restli-Protocol-Version") != "2.0.0" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch {
		case r.URL.Path == "/rest/organizationAcls":
			if r.URL.Query().Get("q") != "roleAssignee" || r.URL.Query().Get("state") != "APPROVED" {
				t.Errorf("acl query %v", r.URL.Query())
			}
			_, _ = io.WriteString(w, `{"elements":[
				{"organization":"urn:li:organization:200","role":"CONTENT_ADMIN","state":"APPROVED"},
				{"organization":"urn:li:organization:100","role":"CONTENT_ADMIN","state":"APPROVED"},
				{"organization":"urn:li:organization:100","role":"ADMINISTRATOR","state":"APPROVED"},
				{"organization":"urn:li:organization:300","role":"ANALYST","state":"APPROVED"},
				{"organization":"urn:li:organization:400","role":"DIRECT_SPONSORED_CONTENT_POSTER","state":"APPROVED"},
				{"organization":"urn:li:organization:500","role":"ADMINISTRATOR","state":"REQUESTED"},
				{"organization":"urn:li:organization:600","role":"ADMINISTRATOR","state":"REVOKED"}]}`)
		case strings.HasPrefix(r.URL.Path, "/rest/organizations/"):
			id := strings.TrimPrefix(r.URL.Path, "/rest/organizations/")
			if id != "100" && id != "200" {
				t.Errorf("an ignored Page was read: %s", id)
			}
			_, _ = fmt.Fprintf(w, `{"id":%s,"localizedName":"Page %s","vanityName":"page-%s"}`, id, id, id)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	pages, err := o.AdminPages(context.Background(), NewPlaintext(testOrgToken))
	if err != nil || len(pages) != 2 {
		t.Fatalf("pages %+v %v, want 100 and 200", pages, err)
	}
	if pages[0] != (OrgPage{ID: "100", Name: "Page 100", VanityName: "page-100", Role: LinkedInOrgRoleAdmin}) ||
		pages[1] != (OrgPage{ID: "200", Name: "Page 200", VanityName: "page-200", Role: LinkedInOrgRoleContentAdmin}) {
		t.Fatalf("pages %+v", pages)
	}
	if pages[0].URN() != "urn:li:organization:100" {
		t.Fatalf("urn %s", pages[0].URN())
	}
}

// The thumbnail is owned by the Page and the post's author is the Page,
// never a person.
func TestLinkedInOrgPostAsThePage(t *testing.T) {
	var initBody, postBody map[string]any
	var put []byte
	var srvURL string
	o := fakeLinkedInOrg(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/rest/images":
			_ = json.NewDecoder(r.Body).Decode(&initBody)
			_, _ = fmt.Fprintf(w, `{"value":{"uploadUrl":"%s/upload/1","image":"urn:li:image:7"}}`, srvURL)
		case r.URL.Path == "/upload/1" && r.Method == http.MethodPut:
			put, _ = io.ReadAll(r.Body)
		case r.URL.Path == "/rest/posts":
			_ = json.NewDecoder(r.Body).Decode(&postBody)
			w.Header().Set("X-Restli-Id", "urn:li:share:9")
			w.WriteHeader(http.StatusCreated)
		}
	})
	srvURL = o.APIBase
	tok := NewPlaintext(testOrgToken)
	img, err := o.UploadImage(context.Background(), tok, "100", []byte("png"))
	if err != nil || img != "urn:li:image:7" || string(put) != "png" {
		t.Fatalf("upload: %q %v", img, err)
	}
	if owner := initBody["initializeUploadRequest"].(map[string]any)["owner"]; owner != "urn:li:organization:100" {
		t.Fatalf("image owner %v", owner)
	}
	id, err := o.Post(context.Background(), tok, "100",
		Article{Commentary: "Hello (world)", URL: "https://app.example.com/blog/x", Title: "T", Description: "D"}, img)
	if err != nil || id != "urn:li:share:9" {
		t.Fatalf("post: %q %v", id, err)
	}
	art := postBody["content"].(map[string]any)["article"].(map[string]any)
	if postBody["author"] != "urn:li:organization:100" || postBody["commentary"] != `Hello \(world\)` ||
		postBody["visibility"] != "PUBLIC" || postBody["lifecycleState"] != "PUBLISHED" || art["thumbnail"] != "urn:li:image:7" ||
		art["source"] != "https://app.example.com/blog/x" {
		t.Fatalf("post body %v", postBody)
	}
	if LinkedInPostPermalink(id) != "https://www.linkedin.com/feed/update/urn:li:share:9" || LinkedInPostPermalink("") != "" {
		t.Fatalf("permalink %s", LinkedInPostPermalink(id))
	}
}

func TestOrgTokenRefusedAndBundle(t *testing.T) {
	for _, c := range []struct {
		err     error
		refused bool
	}{
		{&HTTPError{Status: 401}, true},
		{fmt.Errorf("w: %w", &HTTPError{Status: 403}), true},
		{&HTTPError{Status: 400}, false}, // a post's 400 fails the post, never the channel
		{&HTTPError{Status: 429}, false},
		{&HTTPError{Status: 500}, false},
		{ErrUnknownOutcome, false},
	} {
		if got := OrgTokenRefused(c.err); got != c.refused {
			t.Errorf("OrgTokenRefused(%v) = %v, want %v", c.err, got, c.refused)
		}
	}
	for _, c := range []struct {
		err     error
		refused bool
	}{
		{&HTTPError{Status: 401}, true},
		{&HTTPError{Status: 403}, true},
		{fmt.Errorf("w: %w", &HTTPError{Status: 400}), true}, // invalid_grant
		{&HTTPError{Status: 429}, false},
		{ErrUnknownOutcome, false},
	} {
		if got := OrgRefreshRefused(c.err); got != c.refused {
			t.Errorf("OrgRefreshRefused(%v) = %v, want %v", c.err, got, c.refused)
		}
	}
	now := time.Unix(1_800_000_000, 0)
	tok := OrgToken{Access: NewPlaintext("a-not-a-secret"), ExpiresAt: now, Refresh: NewPlaintext("r-not-a-secret"), RefreshExpiresAt: now.Add(time.Hour)}
	back, err := ParseOrgToken(tok.Bundle())
	if err != nil || back.Access.Reveal() != "a-not-a-secret" || back.Refresh.Reveal() != "r-not-a-secret" ||
		!back.ExpiresAt.Equal(now) || !back.RefreshExpiresAt.Equal(now.Add(time.Hour)) {
		t.Fatalf("bundle round trip: %+v %v", back, err)
	}
	alone, err := ParseOrgToken(OrgToken{Access: NewPlaintext("a"), ExpiresAt: now}.Bundle())
	if err != nil || alone.Refresh.Reveal() != "" || !alone.RefreshExpiresAt.IsZero() {
		t.Fatalf("access-only bundle: %+v %v", alone, err)
	}
	if fmt.Sprint(tok.Bundle()) != "[redacted]" {
		t.Fatal("a bundle printed its tokens")
	}
	if _, err := ParseOrgToken(NewPlaintext("{}")); err == nil {
		t.Fatal("an empty bundle parsed")
	}
}
