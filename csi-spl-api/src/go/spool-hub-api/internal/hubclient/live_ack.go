package hubclient

// Spec 053 S1, the shown ack (SPL-6517, latency action 7). The hub has
// recorded live acks since rdb 0186 (internal/hub/live_ack.go), but no box
// ever sent one: no box hello carried wire.FeatureLiveAck and nothing wrote a
// wire.TAck frame, so the hub could not tell "in the inbox file" from "on the
// agent's screen" (0 rows, ever: lat-hub a-600, 2026-11-25).
//
// The moment a message is SHOWN is the agent hook's injection
// (spool-agent-hook.sh inject). The hook starts scripts/spool-live-ack.sh,
// i.e. `spool live-ack --as <agent> <msg_id>...`, detached and never waits
// for it. The verb hands the ids to this box's sidecar (`spool hub-run`) over
// the submit socket, and the sidecar writes one TAck frame per id, outcome
// shown, on its warm role=box session. The hub records it once (store
// RecordLiveAck: a shown ack over a shown ack writes nothing).
//
// The verb NEVER dials the hub itself: a role=box hello from it would
// supersede the sidecar's session (last hello wins), and a role=cli session
// cannot ack (the hub records acks from role=box only). No sidecar, an older
// sidecar, or no session within submitWaitSession: the ack is dropped, which
// costs only the hub's knowledge that the message was seen. The inbox copy,
// the injection and the S3 nack path do not change.

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"slices"
	"time"

	"github.com/coder/websocket/wsjson"
	"github.com/google/uuid"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// LiveAckMax caps the ids of one request: the hook shows at most 3 messages
// per injection, so this is far above any real call.
const LiveAckMax = 64

// liveAckReplyTimeout bounds the verb's local round trip: the sidecar's wait
// for a session plus one frame write per id.
func liveAckReplyTimeout() time.Duration { return submitWaitSession + 5*time.Second }

// ErrNoSidecar means no submit listener answered: the ack is dropped.
var ErrNoSidecar = errNoSidecar

// submitLiveAck is the live_ack request of the submit socket.
type submitLiveAck struct {
	Agent  string   `json:"agent"`
	MsgIDs []string `json:"msg_ids"`
}

// liveAckResponse is the sidecar's answer: how many TAck frames it wrote.
type liveAckResponse struct {
	Acked int    `json:"acked"`
	Error string `json:"error,omitempty"`
}

// checkLiveAck refuses what the hub would drop anyway: an agent id that is
// not a participant id, a msg_id that is not a UUID, no id or too many ids.
// A repeated id is sent once.
func checkLiveAck(agent string, ids []string) ([]string, error) {
	if !msg.ValidID(agent) {
		return nil, fmt.Errorf("live-ack: %q is not an agent id", agent)
	}
	var out []string
	for _, id := range ids {
		if _, err := uuid.Parse(id); err != nil {
			return nil, fmt.Errorf("live-ack: msg_id %q is not a UUID", id)
		}
		if !slices.Contains(out, id) {
			out = append(out, id)
		}
	}
	if len(out) == 0 || len(out) > LiveAckMax {
		return nil, fmt.Errorf("live-ack: 1..%d msg ids, got %d", LiveAckMax, len(out))
	}
	return out, nil
}

// LiveAckShown hands the sidecar agent's shown ack of ids and returns how
// many frames it wrote. ErrNoSidecar: nothing listens, the ack is dropped.
func (c *Client) LiveAckShown(ctx context.Context, agent string, ids []string) (int, error) {
	ids, err := checkLiveAck(agent, ids)
	if err != nil {
		return 0, err
	}
	path := c.Cfg.SubmitPath()
	if path == "" {
		return 0, ErrNoSidecar
	}
	d := net.Dialer{Timeout: submitDialTimeout}
	conn, err := d.DialContext(ctx, "unix", path)
	if err != nil {
		return 0, ErrNoSidecar
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(liveAckReplyTimeout())) //nolint:errcheck
	line, err := json.Marshal(submitRequest{V: 1, LiveAck: &submitLiveAck{Agent: agent, MsgIDs: ids}})
	if err != nil {
		return 0, err
	}
	if _, err := conn.Write(append(line, '\n')); err != nil {
		return 0, fmt.Errorf("%w: live-ack write: %w", ErrUnreachable, err)
	}
	var resp liveAckResponse
	if err := json.NewDecoder(bufio.NewReader(conn)).Decode(&resp); err != nil {
		return 0, fmt.Errorf("%w: live-ack reply: %w", ErrUnreachable, err)
	}
	if resp.Error != "" {
		return resp.Acked, errors.New("live-ack: sidecar: " + resp.Error)
	}
	return resp.Acked, nil
}

// handleLiveAck answers one live_ack request on conn.
func (s *SubmitServer) handleLiveAck(ctx context.Context, conn net.Conn, a *submitLiveAck) {
	n, err := s.liveAck(ctx, a)
	r := liveAckResponse{Acked: n}
	if err != nil {
		s.c.Log.Info().Err(err).Str("agent", a.Agent).Int("acked", n).Msg("live ack dropped")
		r.Error = err.Error()
	}
	line, _ := json.Marshal(r)
	conn.Write(append(line, '\n')) //nolint:errcheck
}

// liveAck writes one TAck frame (outcome shown) per id on the current
// session. No session within submitWaitSession: none is written.
func (s *SubmitServer) liveAck(ctx context.Context, a *submitLiveAck) (int, error) {
	ids, err := checkLiveAck(a.Agent, a.MsgIDs)
	if err != nil {
		return 0, err
	}
	sess := s.session(ctx, nil, submitWaitSession)
	if sess == nil {
		return 0, fmt.Errorf("%w: no hub session", ErrUnreachable)
	}
	for i, id := range ids {
		if err := sess.liveAck(a.Agent, id, wire.AckShown); err != nil {
			return i, err
		}
	}
	return len(ids), nil
}

// liveAck writes one TAck frame. Fire and forget: the hub sends no reply. The
// write runs on the session ctx, so a session that is ending does not wait on
// a dead socket.
func (s *Session) liveAck(agent, msgID, outcome string) error {
	ctx, cancel := context.WithTimeout(s.ctx, 5*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, s.conn, wire.Frame{Type: wire.TAck, MsgID: msgID, Agent: agent, Outcome: outcome}); err != nil {
		return fmt.Errorf("%w: live ack: %w", ErrUnreachable, err)
	}
	return nil
}
