package marketing

import (
	"context"
	"errors"
	"net/http"
	"testing"
)

// SPL-4763 (refactor round 23, row 07): ContainerStateError.Error, Permalink
// and the PublishInstagramContainer error branches against the httptest fake
// of meta_client_test.go. No network.

// mpPermalinkFake answers GET /v26.0/post1 with status and body, and counts
// the calls.
func mpPermalinkFake(t *testing.T, status int, body string, calls *int) func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		*calls++
		wantBearer(t, r, fakePageAT)
		if r.Method != http.MethodGet || r.URL.Path != "/v26.0/post1" {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		metaJSON(w, status, body)
	}
}

func TestContainerStateErrorFormat(t *testing.T) {
	e := &ContainerStateError{ContainerID: "cont1", Status: ContainerStatus{Code: ContainerErrored, Detail: "ERROR: bad media"}, cause: ErrContainerFailed}
	want := ErrContainerFailed.Error() + " (container cont1, status " + ContainerErrored + ": ERROR: bad media)"
	if got := e.Error(); got != want {
		t.Errorf("Error() = %q, want %q", got, want)
	}
}

func TestPermalinkReadsField(t *testing.T) {
	ctx, tok := context.Background(), NewPlaintext(fakePageAT)
	for _, c := range []struct {
		field, body, want string
	}{
		{PermalinkFacebook, `{"permalink_url":"https://www.example.com/p/1","id":"post1"}`, "https://www.example.com/p/1"},
		{PermalinkInstagram, `{"permalink":"https://www.example.com/i/1","id":"post1"}`, "https://www.example.com/i/1"},
		{PermalinkInstagram, `{"permalink":"","id":"post1"}`, ""},
		{PermalinkFacebook, `{"id":"post1"}`, ""},
	} {
		calls := 0
		m, _ := fakeMeta(t, mpPermalinkFake(t, 200, c.body, &calls))
		got, err := m.Permalink(ctx, tok, "post1", c.field)
		if err != nil || got != c.want || calls != 1 {
			t.Errorf("%s %s: (%q, %v) after %d calls, want (%q, nil)", c.field, c.body, got, err, calls, c.want)
		}
	}
}

// Red control of row 07: the server answers 200 with a link, so only the
// field check refuses an unknown field; a bad id never reaches the server.
func TestPermalinkRefusesBadInput(t *testing.T) {
	ctx, tok := context.Background(), NewPlaintext(fakePageAT)
	for _, c := range []struct{ id, field string }{
		{"", PermalinkFacebook},
		{"a/b", PermalinkInstagram},
		{"post1", "message"},
		{"post1", ""},
	} {
		calls := 0
		m, _ := fakeMeta(t, mpPermalinkFake(t, 200, `{"message":"https://www.example.com/p/1","permalink_url":"https://www.example.com/p/1"}`, &calls))
		got, err := m.Permalink(ctx, tok, c.id, c.field)
		if err == nil || got != "" || calls != 0 {
			t.Errorf("id %q field %q: (%q, %v) after %d calls, want an error and no call", c.id, c.field, got, err, calls)
		}
	}
}

func TestPermalinkHTTPError(t *testing.T) {
	calls := 0
	m, _ := fakeMeta(t, mpPermalinkFake(t, 500, metaGraphErr(2, 0, "OAuthException"), &calls))
	m.Attempts = 1
	got, err := m.Permalink(context.Background(), NewPlaintext(fakePageAT), "post1", PermalinkFacebook)
	if err == nil || got != "" || calls != 1 {
		t.Errorf("(%q, %v) after %d calls, want an error after 1 call", got, err, calls)
	}
}

func TestPublishInstagramContainerErrors(t *testing.T) {
	ctx, tok := context.Background(), NewPlaintext(fakePageAT)
	published := 0
	m, f := fakeMeta(t, igFake(t, ContainerFinished, &published))
	if _, err := m.PublishInstagramContainer(ctx, tok, "ig/1", "cont1"); err == nil || f.calls.Load() != 0 {
		t.Errorf("bad igUserID: err %v after %d calls, want an error and no call", err, f.calls.Load())
	}

	m, _ = fakeMeta(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/v26.0/cont1":
			metaJSON(w, 200, `{"status_code":"`+ContainerFinished+`","status":"done","id":"cont1"}`)
		case r.Method == http.MethodPost && r.URL.Path == "/v26.0/ig1/media_publish":
			metaJSON(w, 200, `{"id":""}`)
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
	})
	media, err := m.PublishInstagramContainer(ctx, tok, "ig1", "cont1")
	var cse *ContainerStateError
	if err == nil || media != "" || errors.As(err, &cse) {
		t.Errorf("empty media id: (%q, %v), want a plain error", media, err)
	}
}
