package hub

import (
	"context"
	"errors"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The record-only path (spec 058 section 7, SPL-6513, latency action 3).
//
// A same-box message is delivered by its own box: the inbox file and the
// poke are written there and never wait on the hub. Measured 2026-11-25 by
// the latency panel (lat-hub, lat-box), 0 % of about 3,700 such messages a
// day reached the hub, so the owner saw none of them. The box now sends a
// record-only copy afterwards, in the background (scripts/spool-record-
// forward.sh -> `spool send --record-of`): a send frame with record_only.
//
// The hub stores it as a message row (the WUI and the Flow show it) and
// delivers it to NO box: no deliveries row, no push, no channel fan-out, no
// tail frame. It is idempotent by msg_id: a msg_id the hub already holds
// (a retry, a resend with a new ts, a message that already reached the hub
// another way) records nothing and answers `recorded` all the same.
//
// A record names its own box as to_box (the message never left it); any
// other to_box is refused, so the frame is never a way to place a message
// in another box's view without delivering it.

// tokenRecordNotLocal refuses a record_only frame whose to_box is not the
// sending box.
const tokenRecordNotLocal = "record_not_local"

// onRecord stores env as a record-only message and answers the sent frame
// with delivery `recorded`. onSend ran every refusal before it.
func (s *Server) onRecord(ctx context.Context, x *session, env *wire.Envelope, m *msg.Message, level int, typedBy string) {
	id := m.MsgID
	if env.ToBox != x.box {
		x.fail(ctx, id, tokenRecordNotLocal, http.StatusBadRequest, "a record_only message names its own box as to_box")
		return
	}
	if err := s.commitRecord(ctx, x.tenant, env, m, level, typedBy); err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", id).Msg("store record-only message")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "message not recorded")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TSent, MsgID: id, TaskID: m.TaskID, TS: m.TS, ToBox: env.ToBox, Delivery: wire.DeliveryRecorded}) //nolint:errcheck
}

// commitRecord stores the row once and shows it to the browsers; nil when
// the msg_id is already held, whatever envelope holds it.
func (s *Server) commitRecord(ctx context.Context, tenant string, env *wire.Envelope, m *msg.Message, level int, typedBy string) error {
	if has, err := s.o.Store.HasMessage(ctx, tenant, m.MsgID); err != nil || has {
		return err
	}
	if level != 1 {
		level = 0
	}
	row, err := s.messageRow(ctx, tenant, env, m, level, typedBy)
	if err != nil {
		return err
	}
	inserted, _, err := s.insertRow(ctx, row)
	if errors.Is(err, store.ErrConflict) { // a concurrent copy of the same msg_id won
		return nil
	}
	if err != nil {
		return err
	}
	if inserted {
		s.fanoutWUI(ctx, row)
	}
	return nil
}
