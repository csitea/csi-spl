package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// An agent's issue requests over its own box socket (specs/039 FR-008,
// issues-v1 §6). The owner: agents formulate concrete, specced work as
// issues and post its progress there. The socket's hello proved the box;
// the acting agent must be one that box announced (the same rule as a send,
// senderRefusal). A reply is an `issue` frame with the request's msg_id.

// issueCommentMax is the longest comment an agent posts in one frame.
const issueCommentMax = 20000

func (s *Server) onIssue(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "an issue frame needs msg_id (a UUID) to pair the reply")
		return
	}
	if detail := senderRefusal(x, f.As); detail != "" {
		x.fail(ctx, id, TokenFromNotAnnounced, http.StatusForbidden, detail)
		return
	}
	out, ie := s.agentIssueOp(ctx, x, f)
	if ie != nil {
		x.fail(ctx, id, ie.token, ie.status, ie.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TIssue, MsgID: id, IssueOp: f.IssueOp, Issue: raw}) //nolint:errcheck
}

// agentIssueOp answers one issue op for the acting agent f.As. Every op but
// get and list writes, and a write needs a paying tenant.
func (s *Server) agentIssueOp(ctx context.Context, x *session, f wire.Frame) (any, *issueErr) {
	if f.IssueOp != "get" && f.IssueOp != "list" {
		if ie := s.issueWriteAllowed(ctx, x.tenant); ie != nil {
			return nil, ie
		}
	}
	switch f.IssueOp {
	case "list":
		return s.agentListIssues(ctx, x.tenant, f.As, f.Query)
	case "get":
		return s.agentGetIssue(ctx, x.tenant, f.IssueRef)
	case "create":
		return s.agentCreateIssue(ctx, x.tenant, f.As, f.Issue)
	case "update":
		return s.agentUpdateIssue(ctx, x.tenant, f.As, f.IssueRef, f.Issue)
	case "label":
		return s.agentCreateLabel(ctx, x.tenant, f.As, f.Issue)
	case "comment":
		return s.agentComment(ctx, x, f.As, f.IssueRef, f.Body)
	}
	return nil, &issueErr{http.StatusBadRequest, "bad_frame", "issue_op must be create, update, get, list, label or comment"}
}

// issueWriteAllowed refuses a write while the tenant's billing is unpaid.
func (s *Server) issueWriteAllowed(ctx context.Context, tenant string) *issueErr {
	t, err := s.o.Store.GetTenant(ctx, tenant)
	if err != nil {
		return &issueErr{http.StatusInternalServerError, "internal", "tenant unavailable"}
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		return &issueErr{billing.HTTPUnpaid, billing.TokenUnpaid, "tenant billing is unpaid"}
	}
	return nil
}

// agentListIssues is list: the filter comes as a URL query string.
func (s *Server) agentListIssues(ctx context.Context, tenant, as, query string) (any, *issueErr) {
	q, err := url.ParseQuery(query)
	if err != nil {
		return nil, badIssue("query must be URL query form, e.g. status=todo&assignee=me")
	}
	fl, ie := parseIssueFilter(q, as)
	if ie != nil {
		return nil, ie
	}
	return s.listIssues(ctx, tenant, fl)
}

// agentCreateIssue is create: the issue object of issues-v1 §3.
func (s *Server) agentCreateIssue(ctx context.Context, tenant, as string, raw json.RawMessage) (any, *issueErr) {
	q, ie := decodeIssueFrame(raw)
	if ie != nil {
		return nil, ie
	}
	i, ie := s.createIssue(ctx, tenant, as, q)
	if ie != nil {
		return nil, ie
	}
	return map[string]any{"issue": toIssueJSON(i, s.storeGetter(ctx, tenant))}, nil
}

// agentUpdateIssue is update: ref names the issue, raw carries the fields
// that change.
func (s *Server) agentUpdateIssue(ctx context.Context, tenant, as, ref string, raw json.RawMessage) (any, *issueErr) {
	n, ok := store.ParseIssueRef(ref)
	if !ok {
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such issue"}
	}
	q, ie := decodeIssueFrame(raw)
	if ie != nil {
		return nil, ie
	}
	i, ie := s.updateIssue(ctx, tenant, as, n, q)
	if ie != nil {
		return nil, ie
	}
	return map[string]any{"issue": toIssueJSON(i, s.storeGetter(ctx, tenant))}, nil
}

// agentCreateLabel is label: {name, color?}.
func (s *Server) agentCreateLabel(ctx context.Context, tenant, as string, raw json.RawMessage) (any, *issueErr) {
	var body struct {
		Name  string `json:"name"`
		Color string `json:"color"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		return nil, &issueErr{http.StatusBadRequest, "bad_json", "issue must be {name, color?}"}
	}
	l, ie := s.createIssueLabel(ctx, tenant, as, body.Name, body.Color)
	if ie != nil {
		return nil, ie
	}
	return map[string]any{"label": toLabelJSON(l)}, nil
}

func decodeIssueFrame(raw json.RawMessage) (issueRequest, *issueErr) {
	var q issueRequest
	if len(raw) == 0 {
		return q, &issueErr{http.StatusBadRequest, "bad_json", "issue is required"}
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&q); err != nil {
		return q, &issueErr{http.StatusBadRequest, "bad_json", "issue must be an issue object (issues-v1 §3)"}
	}
	return q, nil
}

func (s *Server) agentGetIssue(ctx context.Context, tenant, ref string) (any, *issueErr) {
	is, ie := s.issueStore()
	if ie != nil {
		return nil, ie
	}
	n, ok := store.ParseIssueRef(ref)
	if !ok {
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such issue"}
	}
	i, err := is.GetIssue(ctx, tenant, n)
	if ie := storeIssueErr(err); ie != nil {
		return nil, ie
	}
	return map[string]any{"issue": toIssueJSON(i, s.storeGetter(ctx, tenant))}, nil
}

// agentComment posts the agent's progress line into the issue's discussion
// topic: reply level (033 level 2) in the issue channel, so it shows in the
// issue's right pane and never as a card in any feed. The hub builds the
// message, like a browser post; it is shown in browsers and delivered to no
// box.
func (s *Server) agentComment(ctx context.Context, x *session, agent, ref, body string) (any, *issueErr) {
	body = strings.TrimSpace(body)
	if body == "" || !utf8.ValidString(body) || utf8.RuneCountInString(body) > issueCommentMax {
		return nil, badIssue("body must be 1..20000 characters of UTF-8")
	}
	is, ie := s.issueStore()
	if ie != nil {
		return nil, ie
	}
	n, ok := store.ParseIssueRef(ref)
	if !ok {
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such issue"}
	}
	i, err := is.GetIssue(ctx, x.tenant, n)
	if ie := storeIssueErr(err); ie != nil {
		return nil, ie
	}
	m := &msg.Message{V: s.writeVersion(), MsgID: uid.New(), TaskID: i.TaskID, TS: s.o.Now().UTC().Format(time.RFC3339),
		From: agent, To: BroadcastID, Kind: "note", Body: body, Files: []msg.Attachment{}}
	if err := m.Validate(); err != nil {
		return nil, badIssue(err.Error())
	}
	if tok, status, detail := s.admit(ctx, x.tenant, "", m); tok != "" {
		return nil, &issueErr{status, tok, detail}
	}
	inner, err := msg.Canonical(m)
	if err != nil {
		return nil, badIssue("comment does not encode")
	}
	env := &wire.Envelope{FromBox: x.box, ToBox: WUIBox, Channel: IssueChannel, Msg: inner, Sig: ""}
	if _, err := s.commitRow(ctx, x.tenant, env, m, 0); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("issue", i.Key()).Msg("issue comment")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "comment not stored"}
	}
	return map[string]any{"issue": i.Key(), "msg_id": m.MsgID, "task_id": i.TaskID, "channel": IssueChannel}, nil
}
