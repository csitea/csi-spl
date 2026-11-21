package translate

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The client posts the v3 body with the bearer token to <URL>:translateText
// and reads the one translation; a non-200 is an error.
func TestTranslateCallsV3(t *testing.T) {
	var got map[string]any
	var auth, path string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth, path = r.Header.Get("Authorization"), r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		json.Unmarshal(raw, &got) //nolint:errcheck
		if got["targetLanguageCode"] == "xx" {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		w.Write([]byte(`{"translations":[{"translatedText":"Palkka <span translate=\"no\">[NAME_1]</span> &amp; muu"}]}`)) //nolint:errcheck
	}))
	defer srv.Close()
	c := &Client{URL: srv.URL + "/v3/projects/p/locations/global", Token: func(context.Context) (string, error) { return "tok", nil }}
	out, err := c.Translate(context.Background(), Wrap("Salary [NAME_1] & other"), "en", "fi")
	if err != nil {
		t.Fatal(err)
	}
	if auth != "Bearer tok" || path != "/v3/projects/p/locations/global:translateText" {
		t.Errorf("auth %q path %q", auth, path)
	}
	if got["mimeType"] != "text/html" || got["sourceLanguageCode"] != "en" ||
		got["contents"].([]any)[0] != `Salary <span translate="no">[NAME_1]</span> &amp; other` {
		t.Errorf("body: %v", got)
	}
	if plain := Unwrap(out); plain != "Palkka [NAME_1] & muu" {
		t.Errorf("unwrap: %q", plain)
	}
	if _, err := c.Translate(context.Background(), "x", "en", "xx"); err == nil || !strings.Contains(err.Error(), "429") {
		t.Errorf("a 429 is an error: %v", err)
	}
}

// The cap is per UTC day: a reservation that would pass it takes nothing,
// the next day starts at zero.
func TestReserveDailyCap(t *testing.T) {
	now := time.Date(2026, 11, 21, 23, 0, 0, 0, time.UTC)
	c := &Client{DailyChars: 100, Now: func() time.Time { return now }}
	if !c.Reserve(60) || c.Reserve(41) || !c.Reserve(40) || c.Reserve(1) {
		t.Fatal("the cap: 60 + 40 fit, 41 and 1 more do not")
	}
	now = now.Add(2 * time.Hour)
	if !c.Reserve(100) {
		t.Error("a new UTC day starts at zero")
	}
	if !(&Client{}).Reserve(1 << 30) {
		t.Error("a zero cap is no cap")
	}
}

// A span the API changed stays in the text, for the caller's check.
func TestUnwrapKeepsAChangedSpan(t *testing.T) {
	if got := Unwrap(`<span translate="no">[NOM_1]</span>`); !strings.Contains(got, "<span") {
		t.Errorf("unwrap: %q", got)
	}
}
