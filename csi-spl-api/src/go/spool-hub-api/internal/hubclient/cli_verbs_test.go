package hubclient

// r46-08: the one-shot cli verbs MoveMessage, TopicList and FlowRead (the
// Client dial and the Session frame) through opsHub (opshub_test.go), and
// DialStatusError.Unwrap. Each verb: the frame type sent, the msg_id match
// (a decoy reply under another id is skipped) and the raw object returned;
// a hub error frame comes back as a *HubError.

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// cvDecoy and cvAnswer are the raw objects the hub returns: the decoy under
// another msg_id first, then the answer under the request's own id.
var (
	cvDecoy  = json.RawMessage(`{"decoy":true}`)
	cvAnswer = json.RawMessage(`{"answer":true}`)
)

// cvSet puts raw under the reply field of frame type typ.
func cvSet(f *wire.Frame, typ string, raw json.RawMessage) {
	switch typ {
	case wire.TMove:
		f.Move = raw
	case wire.TTopicList:
		f.TopicList = raw
	case wire.TFlowRead:
		f.Flow = raw
	}
}

// cvHub answers each request with a decoy under another msg_id, then the
// answer under its own; with refuse it answers a hub error frame instead.
func cvHub(refuse bool) *opsHub {
	return &opsHub{reply: func(f wire.Frame) []wire.Frame {
		if refuse {
			return []wire.Frame{{Type: wire.TError, MsgID: f.MsgID, Error: "forbidden", Status: 403, Detail: "not seated"}}
		}
		decoy := wire.Frame{Type: f.Type, MsgID: f.MsgID + "-other"}
		cvSet(&decoy, f.Type, cvDecoy)
		answer := wire.Frame{Type: f.Type, MsgID: f.MsgID}
		cvSet(&answer, f.Type, cvAnswer)
		return []wire.Frame{decoy, answer}
	}}
}

// cvClient is opsClient with a short reply wait, so a verb that sends the
// wrong frame type fails in a second instead of the default wait.
func cvClient(t *testing.T, h *opsHub) *Client {
	t.Helper()
	c := opsClient(t, h)
	c.ReadyTimeout = time.Second
	return c
}

// cvVerb is one cli verb: the frame type it must send, how to call it on a
// fresh client, and what the sent frame must carry.
type cvVerb struct {
	name  string
	typ   string
	call  func(context.Context, *Client) (json.RawMessage, error)
	check func(*testing.T, wire.Frame)
}

func cvQueryCheck(t *testing.T, f wire.Frame) {
	if f.As != "c-007" || f.Query != "limit=5" {
		t.Errorf("frame as %q query %q, want c-007 limit=5", f.As, f.Query)
	}
}

// cvOnSession dials a role=cli session and runs one Session verb on it.
func cvOnSession(ctx context.Context, c *Client, verb func(*Session) (json.RawMessage, error)) (json.RawMessage, error) {
	s, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer s.Close()
	return verb(s)
}

var cvVerbs = []cvVerb{
	{"MoveMessage", wire.TMove,
		func(ctx context.Context, c *Client) (json.RawMessage, error) {
			return c.MoveMessage(ctx, "msg-1", "task-to", "c-007", "HUM-1")
		},
		func(t *testing.T, f wire.Frame) {
			if f.MoveMsg != "msg-1" || f.MoveToTask != "task-to" || f.As != "c-007" || f.TypedBy != "HUM-1" {
				t.Errorf("move frame %+v", f)
			}
		}},
	{"Client.TopicList", wire.TTopicList,
		func(ctx context.Context, c *Client) (json.RawMessage, error) {
			return c.TopicList(ctx, "c-007", "limit=5")
		}, cvQueryCheck},
	{"Session.TopicList", wire.TTopicList,
		func(ctx context.Context, c *Client) (json.RawMessage, error) {
			return cvOnSession(ctx, c, func(s *Session) (json.RawMessage, error) { return s.TopicList(ctx, "c-007", "limit=5") })
		}, cvQueryCheck},
	{"Client.FlowRead", wire.TFlowRead,
		func(ctx context.Context, c *Client) (json.RawMessage, error) {
			return c.FlowRead(ctx, "c-007", "limit=5")
		}, cvQueryCheck},
	{"Session.FlowRead", wire.TFlowRead,
		func(ctx context.Context, c *Client) (json.RawMessage, error) {
			return cvOnSession(ctx, c, func(s *Session) (json.RawMessage, error) { return s.FlowRead(ctx, "c-007", "limit=5") })
		}, cvQueryCheck},
}

func TestCLIVerbsSendFrameAndReturnMatchedObject(t *testing.T) {
	for _, v := range cvVerbs {
		t.Run(v.name, func(t *testing.T) {
			h := cvHub(false)
			raw, err := v.call(context.Background(), cvClient(t, h))
			if err != nil {
				t.Fatalf("%s: %v", v.name, err)
			}
			sent := h.frames(v.typ)
			if len(sent) != 1 || sent[0].MsgID == "" {
				t.Fatalf("%s sent %d %s frames", v.name, len(sent), v.typ)
			}
			v.check(t, sent[0])
			if string(raw) != string(cvAnswer) {
				t.Errorf("%s returned %s, want the msg_id-matched %s (not the decoy)", v.name, raw, cvAnswer)
			}
		})
	}
}

func TestCLIVerbsHubErrorFrameIsHubError(t *testing.T) {
	for _, v := range cvVerbs {
		t.Run(v.name, func(t *testing.T) {
			raw, err := v.call(context.Background(), cvClient(t, cvHub(true)))
			var he *HubError
			if !errors.As(err, &he) {
				t.Fatalf("%s error %v (%T), want a *HubError", v.name, err, err)
			}
			if he.Token != "forbidden" || he.Status != 403 || he.Detail != "not seated" {
				t.Errorf("%s HubError %+v", v.name, he)
			}
			if raw != nil {
				t.Errorf("%s returned %s with its error", v.name, raw)
			}
		})
	}
}

func TestDialStatusErrorUnwrapsItsCause(t *testing.T) {
	cvSentinel := errors.New("cv sentinel")
	var err error = &DialStatusError{Status: 503, Err: cvSentinel}
	if !errors.Is(err, cvSentinel) {
		t.Fatalf("errors.Is(DialStatusError{Err: sentinel}, sentinel) = false")
	}
	if errors.Is(err, ErrUnreachable) {
		t.Errorf("errors.Is matched ErrUnreachable, which it does not wrap")
	}
}
