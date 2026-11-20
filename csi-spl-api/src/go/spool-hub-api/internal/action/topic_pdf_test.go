package action

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// Spec 183 row P3: action.TopicPDF over several desks, with the per-desk
// export replaced. Each tenant answers by its entry in by: a body is a PDF,
// an error is that desk's refusal.
func fakeExport(t *testing.T, by map[string]any, tried *[]string) {
	t.Helper()
	old := topicPDFExport
	t.Cleanup(func() { topicPDFExport = old })
	topicPDFExport = func(ctx context.Context, cfg *config.Config, task, typedBy string, w io.Writer) (hubclient.TopicPDFInfo, error) {
		*tried = append(*tried, cfg.Tenant)
		switch v := by[cfg.Tenant].(type) {
		case string:
			w.Write([]byte(v)) //nolint:errcheck
			return hubclient.TopicPDFInfo{Name: "x-" + task[:8] + ".pdf", Rows: 2, Pictures: 1}, nil
		case error:
			w.Write([]byte("partial")) //nolint:errcheck // the next try starts from an empty file
			return hubclient.TopicPDFInfo{}, v
		case time.Duration:
			<-ctx.Done()
			return hubclient.TopicPDFInfo{}, fmt.Errorf("%w: %w", hubclient.ErrUnreachable, ctx.Err())
		}
		return hubclient.TopicPDFInfo{}, &hubclient.HubError{Token: "not_found", Status: 404}
	}
}

var (
	notFound    = &hubclient.HubError{Token: "not_found", Status: 404}
	unreachable = fmt.Errorf("%w: dial refused", hubclient.ErrUnreachable)
)

// The link's workspace is asked first; a 404 hands over to the next desk,
// whose bytes (not the partial ones of the first try) are the file.
func TestTopicPDFDeskOrderAndHandOver(t *testing.T) {
	d := fakeDesks(t, "box-desk", []string{"aaa", "csitea", "zzz"}, nil)
	d.Base = testkit.NewConfig(t)
	var tried []string
	fakeExport(t, map[string]any{"csitea": notFound, "aaa": unreachable, "zzz": "%PDF-zzz"}, &tried)
	out := filepath.Join(t.TempDir(), "t.pdf")
	res, err := TopicPDF(context.Background(), d, TopicPDFArgs{Task: "https://csitea.example.net/t/" + linkTask, Out: out})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(tried, ",") != "csitea,aaa,zzz" {
		t.Errorf("tried %v, want the link's workspace first", tried)
	}
	sum := sha256.Sum256([]byte("%PDF-zzz"))
	if b, _ := os.ReadFile(out); string(b) != "%PDF-zzz" || res.SHA256 != hex.EncodeToString(sum[:]) || res.Bytes != 8 || res.Rows != 2 || res.Pictures != 1 {
		t.Errorf("file %q result %+v", b, res)
	}
}

// No desk serves it: an unreachable desk is reported before a 404 (exit 1,
// not 3); 404 everywhere is exit 3; a refusal other than 404 stops at once.
func TestTopicPDFRefusals(t *testing.T) {
	cases := []struct {
		by    map[string]any
		rc    int
		tried string
	}{
		{map[string]any{"aaa": notFound, "bbb": unreachable}, 1, "aaa,bbb"},
		{map[string]any{"aaa": notFound, "bbb": notFound}, ExitTopicPDFNotFound, "aaa,bbb"},
		{map[string]any{"aaa": &hubclient.HubError{Token: "operator_ambiguous", Status: 400}, "bbb": "%PDF"}, ExitTopicPDFOperator, "aaa"},
		{map[string]any{"aaa": &hubclient.HubError{Token: "render_unavailable", Status: 503}, "bbb": "%PDF"}, ExitTopicPDFRender, "aaa"},
	}
	for i, c := range cases {
		d := fakeDesks(t, "box-desk", []string{"aaa", "bbb"}, nil)
		d.Base = testkit.NewConfig(t)
		var tried []string
		fakeExport(t, c.by, &tried)
		dir := t.TempDir()
		_, err := TopicPDF(context.Background(), d, TopicPDFArgs{Task: linkTask, Out: filepath.Join(dir, "t.pdf")})
		if rc := TopicPDFExitCode(err); err == nil || rc != c.rc || strings.Join(tried, ",") != c.tried {
			t.Errorf("case %d: err %v rc %d tried %v, want rc %d tried %s", i, err, rc, tried, c.rc, c.tried)
		}
		if left, _ := os.ReadDir(dir); len(left) != 0 {
			t.Errorf("case %d: left %v", i, left)
		}
	}
}

// A desk that answers nothing within the timeout: render_timeout, exit 5.
func TestTopicPDFTimeout(t *testing.T) {
	d := Desks{Base: testkit.NewConfig(t)}
	d.Base.HubURL, d.Base.Tenant = "https://api.example.net", "t1"
	var tried []string
	fakeExport(t, map[string]any{"t1": time.Second}, &tried)
	_, err := TopicPDF(context.Background(), d, TopicPDFArgs{Task: linkTask, Out: filepath.Join(t.TempDir(), "t.pdf"), Timeout: 20 * time.Millisecond})
	if !errors.Is(err, ErrTopicPDFTimeout) || TopicPDFExitCode(err) != ExitTopicPDFRender {
		t.Fatalf("got %v", err)
	}
}

// The default target: $SPOOL_ROOT/<agent>/exports, the agent from Agent,
// else $SPOOL_AGENT_ID, else the box id; the hub's name, else topic-<task8>-<stamp>.pdf.
func TestTopicPDFTarget(t *testing.T) {
	base := testkit.NewConfig(t)
	base.BoxID = "box-a"
	t.Setenv("SPOOL_AGENT_ID", "")
	for _, c := range []struct{ agent, env, want string }{
		{"c-007", "c-008", "c-007"}, {"", "c-008", "c-008"}, {"", "", "box-a"},
	} {
		t.Setenv("SPOOL_AGENT_ID", c.env)
		dir, path, err := topicPDFTarget(base, TopicPDFArgs{Agent: c.agent})
		if err != nil || path != "" || dir != filepath.Join(base.SpoolRoot, c.want, "exports") {
			t.Errorf("%+v: dir %q path %q err %v", c, dir, path, err)
		}
		if fi, err := os.Stat(dir); err != nil || fi.Mode().Perm() != 0o700 {
			t.Errorf("%+v: %v %v", c, fi, err)
		}
	}
	for _, bad := range []TopicPDFArgs{{Agent: "../x"}, {Out: t.TempDir()}} {
		if _, _, err := topicPDFTarget(base, bad); err == nil {
			t.Errorf("%+v: no refusal", bad)
		}
	}
	if _, _, err := topicPDFTarget(nil, TopicPDFArgs{}); err == nil {
		t.Error("no base, no out: no refusal")
	}
	if got := topicPDFName("", linkTask); !strings.HasPrefix(got, "topic-"+linkTask[:8]+"-") || !strings.HasSuffix(got, "Z.pdf") {
		t.Errorf("fallback name %q", got)
	}
	if got := topicPDFName("hub.pdf", linkTask); got != "hub.pdf" {
		t.Errorf("hub name %q", got)
	}
}

// Usage: a bad link, a typed_by that is no person, and no desk at all.
func TestTopicPDFUsageRefusals(t *testing.T) {
	base := testkit.NewConfig(t)
	for _, in := range []TopicPDFArgs{{Task: "nope"}, {Task: linkTask, TypedBy: "c-007"}, {Task: linkTask}} {
		if _, err := TopicPDF(context.Background(), Desks{Base: base}, in); err == nil || TopicPDFExitCode(err) != 1 {
			t.Errorf("%+v: %v", in, err)
		}
	}
}
