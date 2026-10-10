package hubclient

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// r7-04: each one-shot CLI op dials role=cli, sends ONE request frame with a
// fresh msg_id and returns the answer object of the reply that matches it.
func TestCLIRequestOps(t *testing.T) {
	ctx := context.Background()
	body := json.RawMessage(`{"k":"v"}`)
	cases := []struct {
		name, typ, op string
		call          func(c *Client) (json.RawMessage, error)
		sent          func(f wire.Frame) bool
	}{
		{"ask", wire.TAsk, "put", func(c *Client) (json.RawMessage, error) { return c.Ask(ctx, "put", "fl", body) },
			func(f wire.Frame) bool { return f.AskOp == "put" && f.Fleet == "fl" && string(f.Ask) == string(body) }},
		{"claim", wire.TClaim, "poll", func(c *Client) (json.RawMessage, error) { return c.Claim(ctx, "poll", body) },
			func(f wire.Frame) bool { return f.ClaimOp == "poll" && string(f.Claim) == string(body) }},
		{"lane", wire.TLane, "list", func(c *Client) (json.RawMessage, error) { return c.Lane(ctx, "list", "fl", nil) },
			func(f wire.Frame) bool { return f.LaneOp == "list" && f.Fleet == "fl" }},
		{"lease", wire.TLease, "cas", func(c *Client) (json.RawMessage, error) { return c.Lease(ctx, "cas", "fl", "orch", "c-007", 3) },
			func(f wire.Frame) bool { return f.LeaseRole == "orch" && f.Holder == "c-007" && f.IfGen == 3 }},
		{"move", wire.TMove, "ops", func(c *Client) (json.RawMessage, error) { return c.MoveTopic(ctx, "task-1", "ops", "c-007", "HUM-1") },
			func(f wire.Frame) bool { return f.TaskID == "task-1" && f.As == "c-007" && f.TypedBy == "HUM-1" }},
		{"react add", wire.TReact, "add", func(c *Client) (json.RawMessage, error) { return c.React(ctx, "task-1", "m-1", "+1", "c-007", true) },
			func(f wire.Frame) bool { return f.ReactMsg == "m-1" && f.Emoji == "+1" }},
		{"react remove", wire.TReact, "remove", func(c *Client) (json.RawMessage, error) { return c.React(ctx, "task-1", "m-1", "+1", "c-007", false) },
			func(f wire.Frame) bool { return f.ReactOp == "remove" }},
		{"reactions", wire.TReact, "list", func(c *Client) (json.RawMessage, error) { return c.Reactions(ctx, "task-1", "m-1", "c-007") },
			func(f wire.Frame) bool { return f.Emoji == "" }},
		{"archive", wire.TArchive, "archive", func(c *Client) (json.RawMessage, error) { return c.ArchiveTopic(ctx, "task-1", "c-007", true) },
			func(f wire.Frame) bool { return f.TaskID == "task-1" }},
		{"unarchive", wire.TArchive, "unarchive", func(c *Client) (json.RawMessage, error) { return c.ArchiveTopic(ctx, "task-1", "c-007", false) },
			func(f wire.Frame) bool { return f.As == "c-007" }},
		{"issue", wire.TIssue, "get", func(c *Client) (json.RawMessage, error) {
			return c.Issue(ctx, IssueRequest{Op: "get", As: "c-007", Ref: "SPL-1", Query: "q=1", Body: "b"})
		}, func(f wire.Frame) bool { return f.IssueRef == "SPL-1" && f.Query == "q=1" && f.Body == "b" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := &opsHub{}
			c := opsClient(t, h)
			got, err := tc.call(c)
			if err != nil {
				t.Fatal(err)
			}
			if want := string(echo(tc.op)); string(got) != want {
				t.Errorf("answer %s, want %s", got, want)
			}
			fs := h.frames(tc.typ)
			if len(fs) != 1 || fs[0].MsgID == "" || !tc.sent(fs[0]) {
				t.Errorf("request frames %+v", fs)
			}
		})
	}
}

// A hub error frame with no msg_id answers the pending request as a HubError.
func TestCLIRequestOpRefused(t *testing.T) {
	h := &opsHub{reply: func(f wire.Frame) []wire.Frame {
		return []wire.Frame{{Type: wire.TError, Error: "forbidden", Status: 403, Detail: "not yours"}}
	}}
	c := opsClient(t, h)
	_, err := c.Ask(context.Background(), "put", "fl", nil)
	var he *HubError
	if !errors.As(err, &he) || he.Token != "forbidden" || he.Status != 403 || !he.clientError() {
		t.Fatalf("want HubError forbidden 403, got %v", err)
	}
	if !strings.Contains(err.Error(), "not yours") {
		t.Errorf("error %q lost its detail", err)
	}
}

// A hub that never answers ends the request at ReadyTimeout as unreachable.
func TestCLIRequestOpNoReply(t *testing.T) {
	h := &opsHub{reply: func(wire.Frame) []wire.Frame { return nil }}
	c := opsClient(t, h)
	c.ReadyTimeout = 300e6
	if _, err := c.Lane(context.Background(), "list", "fl", nil); !errors.Is(err, ErrUnreachable) {
		t.Fatalf("want ErrUnreachable, got %v", err)
	}
}

// A CLI op on a box with no valid box id never dials.
func TestCLIRequestOpNeedsBox(t *testing.T) {
	h := &opsHub{}
	c := opsClient(t, h)
	c.Cfg.BoxID = "not a box"
	if _, err := c.Claim(context.Background(), "poll", nil); err == nil || !strings.Contains(err.Error(), "SPOOL_BOX_ID") {
		t.Fatalf("got %v", err)
	}
	if n := len(h.frames(wire.TClaim)); n != 0 {
		t.Errorf("%d frames reached the hub", n)
	}
}
