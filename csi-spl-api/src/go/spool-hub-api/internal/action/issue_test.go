package action

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// r15-06: Issue's payload checks before any dial, and what reaches the hub.

// issueHub answers an issue frame with the op it received.
func issueHub(t *testing.T) *opHub {
	t.Helper()
	return newOpHub(t, func(f wire.Frame) wire.Frame {
		if f.Type != wire.TIssue {
			return wire.Frame{Type: wire.TError, Error: "unexpected_frame"}
		}
		b, _ := json.Marshal(map[string]string{"op": f.IssueOp, "ref": f.IssueRef})
		return wire.Frame{Type: wire.TIssue, MsgID: f.MsgID, Issue: b}
	})
}

// TestIssueRefused: an op Issue refuses never dials.
func TestIssueRefused(t *testing.T) {
	h := issueHub(t)
	cfg := opCfg(t, h.url)
	cases := []struct {
		name   string
		hubURL string
		in     IssueArgs
		want   string
	}{
		{"no hub", "", IssueArgs{Op: "get", As: "CLE-1"}, "need hub mode"},
		{"empty op", h.url, IssueArgs{As: "CLE-1"}, "op must be"},
		{"unknown op", h.url, IssueArgs{Op: "close", As: "CLE-1"}, "op must be"},
		{"no as", h.url, IssueArgs{Op: "list"}, "--as (the acting agent id) is required"},
		{"archive no ref", h.url, IssueArgs{Op: "archive", As: "CLE-1"}, "--ref is required"},
		{"unarchive no ref", h.url, IssueArgs{Op: "unarchive", As: "CLE-1"}, "--ref is required"},
		{"link no ref", h.url, IssueArgs{Op: "link", As: "CLE-1", Body: "/t/x"}, "--ref and --discussion"},
		{"link no discussion", h.url, IssueArgs{Op: "link", As: "CLE-1", Ref: "SPL-1"}, "--ref and --discussion"},
		{"unlink no discussion", h.url, IssueArgs{Op: "unlink", As: "CLE-1", Ref: "SPL-1"}, "--ref and --discussion"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg.HubURL = c.hubURL
			if out, err := Issue(context.Background(), cfg, c.in); err == nil || !strings.Contains(err.Error(), c.want) || out != nil {
				t.Fatalf("got %s, %v; want %q", out, err, c.want)
			}
		})
	}
	if n := len(h.of("")); n != 0 {
		t.Errorf("the hub received %d frames for refused requests", n)
	}
}

// TestIssueHub: every op Issue accepts reaches the hub with its fields, on
// the configured client or an injected one.
func TestIssueHub(t *testing.T) {
	h := issueHub(t)
	cfg := opCfg(t, h.url)
	payload := json.RawMessage(`{"title":"t"}`)
	cases := []IssueArgs{
		{Op: "create", As: "CLE-1", Issue: payload},
		{Op: "update", As: "CLE-1", Ref: "SPL-1", Issue: payload},
		{Op: "get", As: "CLE-1", Ref: "SPL-1"},
		{Op: "list", As: "CLE-1", Query: "status=wip"},
		{Op: "label", As: "CLE-1", Ref: "SPL-1", Body: "bug"},
		{Op: "comment", As: "CLE-1", Ref: "SPL-1", Body: "c"},
		{Op: "delete", As: "CLE-1", Ref: "SPL-1"},
		{Op: "archive", As: "CLE-1", Ref: "SPL-1", Query: "cascade=1"},
		{Op: "unarchive", As: "CLE-1", Ref: "SPL-1"},
		{Op: "link", As: "CLE-1", Ref: "SPL-1", Body: "/t/x"},
		{Op: "unlink", As: "CLE-1", Ref: "SPL-1", Body: "/t/x"},
		{Op: "get", As: "CLE-1", Ref: "SPL-2", Hub: hubclient.New(cfg)},
	}
	for i, in := range cases {
		t.Run(in.Op, func(t *testing.T) {
			out, err := Issue(context.Background(), cfg, in)
			if err != nil {
				t.Fatal(err)
			}
			var got map[string]string
			if err := json.Unmarshal(out, &got); err != nil || got["op"] != in.Op || got["ref"] != in.Ref {
				t.Fatalf("answer %s (%v)", out, err)
			}
			fs := h.of(wire.TIssue)
			if len(fs) != i+1 {
				t.Fatalf("%d issue frames, want %d", len(fs), i+1)
			}
			f := fs[i]
			if f.IssueOp != in.Op || f.As != in.As || f.IssueRef != in.Ref || f.Query != in.Query || f.Body != in.Body ||
				string(f.Issue) != string(in.Issue) {
				t.Errorf("frame %+v for %+v", f, in)
			}
		})
	}
}

// TestIssueHubError: a hub refusal comes back as the error.
func TestIssueHubError(t *testing.T) {
	h := newOpHub(t, func(f wire.Frame) wire.Frame {
		return wire.Frame{Type: wire.TError, MsgID: f.MsgID, Error: "forbidden", Status: 403}
	})
	cfg := opCfg(t, h.url)
	if out, err := Issue(context.Background(), cfg, IssueArgs{Op: "get", As: "CLE-1", Ref: "SPL-1"}); err == nil || out != nil {
		t.Fatalf("got %s, %v; want the refusal", out, err)
	}
}
