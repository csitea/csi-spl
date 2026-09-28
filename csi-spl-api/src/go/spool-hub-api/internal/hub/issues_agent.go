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
	write := f.IssueOp != "get" && f.IssueOp != "list"
	if write {
		t, err := s.o.Store.GetTenant(ctx, x.tenant)
		if err != nil {
			x.fail(ctx, id, "internal", http.StatusInternalServerError, "tenant unavailable")
			return
		}
		if !billing.AllowsWrite(t.BillingStatus) {
			x.fail(ctx, id, billing.TokenUnpaid, billing.HTTPUnpaid, "tenant billing is unpaid")
			return
		}
	}
	var out any
	var ie *issueErr
	switch f.IssueOp {
	case "list":
		var q url.Values
		q, err := url.ParseQuery(f.Query)
		if err != nil {
			ie = badIssue("query must be URL query form, e.g. status=todo&assignee=me")
			break
		}
		fl, fie := parseIssueFilter(q, f.As)
		if ie = fie; ie == nil {
			out, ie = s.listIssues(ctx, x.tenant, fl)
		}
	case "get":
		out, ie = s.agentGetIssue(ctx, x.tenant, f.IssueRef)
	case "create":
		var q issueRequest
		if q, ie = decodeIssueFrame(f.Issue); ie == nil {
			var i store.Issue
			if i, ie = s.createIssue(ctx, x.tenant, f.As, q); ie == nil {
				out = map[string]any{"issue": toIssueJSON(i, s.storeGetter(ctx, x.tenant))}
			}
		}
	case "update":
		n, ok := store.ParseIssueRef(f.IssueRef)
		if !ok {
			ie = &issueErr{http.StatusNotFound, "not_found", "no such issue"}
			break
		}
		var q issueRequest
		if q, ie = decodeIssueFrame(f.Issue); ie == nil {
			var i store.Issue
			if i, ie = s.updateIssue(ctx, x.tenant, f.As, n, q); ie == nil {
				out = map[string]any{"issue": toIssueJSON(i, s.storeGetter(ctx, x.tenant))}
			}
		}
	case "label":
		var body struct {
			Name  string `json:"name"`
			Color string `json:"color"`
		}
		dec := json.NewDecoder(bytes.NewReader(f.Issue))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&body); err != nil {
			ie = &issueErr{http.StatusBadRequest, "bad_json", "issue must be {name, color?}"}
			break
		}
		var l store.IssueLabel
		if l, ie = s.createIssueLabel(ctx, x.tenant, f.As, body.Name, body.Color); ie == nil {
			out = map[string]any{"label": toLabelJSON(l)}
		}
	case "comment":
		out, ie = s.agentComment(ctx, x, f.As, f.IssueRef, f.Body)
	default:
		ie = &issueErr{http.StatusBadRequest, "bad_frame", "issue_op must be create, update, get, list, label or comment"}
	}
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
