package hubclient

import (
	"context"
	"encoding/json"

	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// IssueRequest is one agent issue request (specs/039 issues-v1 §6).
type IssueRequest struct {
	Op    string          // create | update | get | list | label | comment
	As    string          // the acting agent; one this box announced
	Ref   string          // issue key for update / get / comment
	Issue json.RawMessage // create / update body, or {name, color} for label
	Query string          // list filters, URL query form
	Body  string          // comment text
}

// Issue asks the hub over a one-shot role=cli session and returns the
// reply's object (issues-v1 §6). A refusal is a *HubError.
func (c *Client) Issue(ctx context.Context, r IssueRequest) (json.RawMessage, error) {
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	return sess.Issue(ctx, r)
}

// Issue sends one issue frame on s and waits for its reply.
func (s *Session) Issue(ctx context.Context, r IssueRequest) (json.RawMessage, error) {
	id := uid.New()
	f, err := s.request(ctx, wire.Frame{Type: wire.TIssue, MsgID: id, IssueOp: r.Op, As: r.As, IssueRef: r.Ref,
		Issue: r.Issue, Query: r.Query, Body: r.Body}, wire.TIssue,
		func(f wire.Frame) bool { return f.MsgID == id || (f.Type == wire.TError && f.MsgID == "") })
	if err != nil {
		return nil, err
	}
	return f.Issue, nil
}
