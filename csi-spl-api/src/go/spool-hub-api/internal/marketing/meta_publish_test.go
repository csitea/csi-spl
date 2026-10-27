package marketing

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

// SPL-3875 (spec 090 T032): the Instagram container flow and the Graph error
// mapping against the httptest fake of meta_client_test.go.

// igFake answers the container flow; status is what the container reports.
func igFake(t *testing.T, status string, published *int) func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r, fakePageAT)
		_ = r.ParseForm()
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v26.0/ig1/media":
			if r.PostForm.Get("image_url") != "https://app.example.com/a.jpg" || r.PostForm.Get("caption") != "Hello #spool" {
				t.Errorf("container form %v", r.PostForm)
			}
			metaJSON(w, 200, `{"id":"cont1"}`)
		case r.Method == http.MethodGet && r.URL.Path == "/v26.0/cont1":
			if r.URL.Query().Get("fields") != "status_code,status" {
				t.Errorf("status fields %q", r.URL.Query().Get("fields"))
			}
			metaJSON(w, 200, `{"status_code":"`+status+`","status":"`+status+`: detail","id":"cont1"}`)
		case r.Method == http.MethodPost && r.URL.Path == "/v26.0/ig1/media_publish":
			*published++
			if r.PostForm.Get("creation_id") != "cont1" {
				t.Errorf("publish form %v", r.PostForm)
			}
			metaJSON(w, 200, `{"id":"media77"}`)
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
	}
}

func TestInstagramTwoStepPublish(t *testing.T) {
	published := 0
	m, _ := fakeMeta(t, igFake(t, ContainerFinished, &published))
	ctx, tok := context.Background(), NewPlaintext(fakePageAT)
	id, err := m.CreateInstagramContainer(ctx, tok, "ig1", InstagramMedia{ImageURL: "https://app.example.com/a.jpg", Caption: "Hello #spool"})
	if err != nil || id != "cont1" {
		t.Fatalf("container %q %v", id, err)
	}
	st, err := m.PollInstagramContainer(ctx, tok, id)
	if err != nil || st.Code != ContainerFinished {
		t.Fatalf("status %+v %v", st, err)
	}
	media, err := m.PublishInstagramContainer(ctx, tok, "ig1", id)
	if err != nil || media != "media77" || published != 1 {
		t.Fatalf("publish %q %v (%d publishes)", media, err, published)
	}
}

// Red control of T032: a container that is not FINISHED is never published,
// and ERROR / EXPIRED / a media refusal fail terminally with a typed error.
func TestInstagramContainerErrorFailsTerminal(t *testing.T) {
	ctx, tok := context.Background(), NewPlaintext(fakePageAT)
	for _, c := range []struct {
		status string
		want   error
	}{
		{ContainerErrored, ErrContainerFailed},
		{ContainerExpired, ErrContainerFailed},
		{ContainerPublished, ErrContainerPublished},
		{ContainerInProgress, ErrContainerNotReady},
	} {
		published := 0
		m, _ := fakeMeta(t, igFake(t, c.status, &published))
		_, err := m.PublishInstagramContainer(ctx, tok, "ig1", "cont1")
		var cse *ContainerStateError
		if !errors.Is(err, c.want) || !errors.As(err, &cse) || cse.Status.Code != c.status || published != 0 {
			t.Errorf("%s: err %v, want %v, %d publishes", c.status, err, c.want, published)
		}
	}
	m, f := fakeMeta(t, func(w http.ResponseWriter, _ *http.Request) {
		metaJSON(w, 400, `{"error":{"message":"The aspect ratio is not supported.","type":"OAuthException","code":36003,"error_subcode":2207009}}`)
	})
	_, err := m.CreateInstagramContainer(ctx, tok, "ig1", InstagramMedia{ImageURL: "https://app.example.com/wide.jpg"})
	var me *MetaError
	if !errors.As(err, &me) || me.Kind != MetaErrMedia || MetaRetryable(err) || f.calls.Load() != 1 {
		t.Fatalf("media refusal: err %v calls %d, want one terminal media error", err, f.calls.Load())
	}
}

func TestInstagramMediaValidation(t *testing.T) {
	m, f := fakeMeta(t, func(w http.ResponseWriter, _ *http.Request) { metaJSON(w, 200, `{"id":"c"}`) })
	ctx, tok := context.Background(), NewPlaintext(fakePageAT)
	for name, md := range map[string]InstagramMedia{
		"http url":     {ImageURL: "http://app.example.com/a.jpg"},
		"no url":       {},
		"long caption": {ImageURL: "https://app.example.com/a.jpg", Caption: strings.Repeat("x", InstagramCaptionMaxChars+1)},
		"31 hashtags":  {ImageURL: "https://app.example.com/a.jpg", Caption: strings.Repeat("#t ", 31)},
		"1-item":       {MediaType: "CAROUSEL", Children: []string{"a"}},
		"bad child":    {MediaType: "CAROUSEL", Children: []string{"a", "b/c"}},
		"unknown type": {MediaType: "VIDEO", ImageURL: "https://app.example.com/a.mp4"},
		"21 items":     {MediaType: "CAROUSEL", Children: strings.Split(strings.Repeat("a,", 20)+"a", ",")},
	} {
		if _, err := m.CreateInstagramContainer(ctx, tok, "ig1", md); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if f.calls.Load() != 0 {
		t.Fatalf("calls %d: a refused container reached Meta", f.calls.Load())
	}
	if _, err := m.CreateInstagramContainer(ctx, tok, "ig1", InstagramMedia{MediaType: "CAROUSEL", Children: []string{"a", "b"}, Caption: "c"}); err != nil {
		t.Fatal(err)
	}
	if _, err := m.CreateInstagramContainer(ctx, tok, "ig1", InstagramMedia{ImageURL: "https://app.example.com/a.jpg", IsCarouselItem: true}); err != nil {
		t.Fatal(err)
	}
}

func TestInstagramContainerRetriedOnTransient(t *testing.T) {
	m, f := fakeMeta(t, func(w http.ResponseWriter, _ *http.Request) {
		metaJSON(w, 500, `{"error":{"message":"Service temporarily unavailable","type":"OAuthException","code":2,"is_transient":true}}`)
	})
	_, err := m.CreateInstagramContainer(context.Background(), NewPlaintext(fakePageAT), "ig1", InstagramMedia{ImageURL: "https://app.example.com/a.jpg"})
	if MetaKind(err) != MetaErrTransient || f.calls.Load() != 3 || len(f.waits) != 2 {
		t.Fatalf("err %v calls %d waits %v: a container is retried 3 times", err, f.calls.Load(), f.waits)
	}
}

func TestMetaTokenExpiredErrorHandling(t *testing.T) {
	m, f := fakeMeta(t, func(w http.ResponseWriter, _ *http.Request) {
		metaJSON(w, 400, `{"error":{"message":"Error validating access token: Session has expired.","type":"OAuthException","code":190,"error_subcode":463,"fbtrace_id":"tr1"}}`)
	})
	_, err := m.PublishFacebookPagePost(context.Background(), NewPlaintext(fakePageAT), "p1", FacebookPost{Message: "x"})
	var me *MetaError
	if !errors.As(err, &me) || !MetaTokenInvalid(err) || MetaRetryable(err) || f.calls.Load() != 1 {
		t.Fatalf("err %v calls %d: want one terminal auth error", err, f.calls.Load())
	}
	if me.Code != 190 || me.Subcode != 463 || me.TraceID != "tr1" || !strings.Contains(me.Message, "Session has expired") {
		t.Fatalf("fields %+v", me)
	}
	if _, err := m.ListAccounts(context.Background(), NewPlaintext(fakeUserAT)); !MetaTokenInvalid(err) || f.calls.Load() != 2 {
		t.Fatalf("list: err %v calls %d: an auth error is never retried", err, f.calls.Load())
	}
}

func TestMetaErrorClassification(t *testing.T) {
	for _, c := range []struct {
		status, code, sub int
		transient         bool
		want              MetaErrorKind
	}{
		{400, 190, 0, false, MetaErrAuth},
		{400, 190, 460, false, MetaErrAuth},
		{401, 0, 0, false, MetaErrAuth},
		{400, 102, 0, false, MetaErrAuth},
		{400, 4, 0, false, MetaErrRateLimit},
		{400, 17, 0, false, MetaErrRateLimit},
		{400, 32, 0, false, MetaErrRateLimit},
		{400, 613, 0, false, MetaErrRateLimit},
		{400, 80002, 0, false, MetaErrRateLimit},
		{400, 9, 2207042, false, MetaErrRateLimit},
		{429, 0, 0, false, MetaErrRateLimit},
		{400, 9007, 2207027, false, MetaErrNotReady},
		{500, 1, 2207001, false, MetaErrTransient},
		{400, 36003, 2207009, false, MetaErrMedia},
		{400, 9004, 2207052, false, MetaErrMedia},
		{400, 100, 2207026, false, MetaErrMedia},
		{403, 10, 0, false, MetaErrPermission},
		{403, 200, 0, false, MetaErrPermission},
		{500, 2, 0, false, MetaErrTransient},
		{400, 100, 0, true, MetaErrTransient},
		{502, 0, 0, false, MetaErrTransient},
		{400, 100, 33, false, MetaErrOther},
	} {
		if got := classifyMeta(c.status, c.code, c.sub, c.transient); got != c.want {
			t.Errorf("classify(%d, %d, %d, %v) = %s, want %s", c.status, c.code, c.sub, c.transient, got, c.want)
		}
	}
	if MetaErrorKind(99).String() != "kind(99)" || MetaKind(errors.New("x")) != MetaErrOther {
		t.Error("kind fallbacks")
	}
}

func TestMetaRateLimitRetryAfter(t *testing.T) {
	m, f := fakeMeta(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Business-Use-Case-Usage", `{"p1":[{"type":"pages","call_count":100,"estimated_time_to_regain_access":7},{"estimated_time_to_regain_access":3}]}`)
		metaJSON(w, 400, metaGraphErr(80001, 0, "OAuthException"))
	})
	_, err := m.ListAccounts(context.Background(), NewPlaintext(fakeUserAT))
	var me *MetaError
	if !errors.As(err, &me) || me.Kind != MetaErrRateLimit || me.RetryAfter != 7*time.Minute || f.calls.Load() != 1 || !MetaRetryable(err) {
		t.Fatalf("err %v calls %d: a rate limit is not retried here but is retryable later", err, f.calls.Load())
	}
	m2, _ := fakeMeta(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Retry-After", "42")
		metaJSON(w, 429, `{}`)
	})
	_, err = m2.ListAccounts(context.Background(), NewPlaintext(fakeUserAT))
	if !errors.As(err, &me) || me.RetryAfter != 42*time.Second {
		t.Fatalf("Retry-After: %v", err)
	}
}

func TestMetaBackoffAndVersion(t *testing.T) {
	m := &Meta{}
	for i, want := range []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 8 * time.Second} {
		if got := m.backoff(i); got != want {
			t.Errorf("backoff(%d) = %v, want %v", i, got, want)
		}
	}
	m.Version = "26"
	if _, err := m.ListAccounts(context.Background(), NewPlaintext(fakeUserAT)); err == nil || !strings.Contains(err.Error(), "vNN.N") {
		t.Fatalf("bad version: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := (&Meta{}).sleep(ctx, time.Hour); !errors.Is(err, context.Canceled) {
		t.Fatalf("sleep on a done ctx: %v", err)
	}
}
