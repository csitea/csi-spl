package hubclient

import (
	"context"
	"errors"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// errInboxWrite marks a recv frame whose inbox copy could not be written: the
// one refusal NOT committed, so the hub sends the frame again (spec 059 S2).
// Every other refusal (a bad signature, a frame for another box) would fail
// the same way next time, so it is committed and not re-sent forever.
var errInboxWrite = errors.New("inbox write")

// commit tells the hub one recv frame is done (wire.TCommit). A lost commit
// costs one duplicate frame later, which the inbox file name absorbs.
//
// A frame whose envelope or inner message does not parse is dropped silently:
// with no msg_id there is nothing to commit. That is safe because an
// uncommitted frame stays queued on the hub and is sent again: the worst case
// is a repeated refusal (receive already logged it), never a lost message.
// The write runs on the session ctx, so a session that is ending does not
// wait up to 5 s on a dead socket.
func (s *Session) commit(raw []byte, recvErr error) {
	if errors.Is(recvErr, errInboxWrite) {
		return
	}
	e, err := wire.ParseEnvelope(raw)
	if err != nil {
		return
	}
	m, err := e.Inner()
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(s.ctx, 5*time.Second)
	defer cancel()
	if err := wsjson.Write(ctx, s.conn, wire.Frame{Type: wire.TCommit, MsgID: m.MsgID}); err != nil {
		s.c.Log.Warn().Err(err).Str("msg_id", m.MsgID).Msg("commit not sent; the hub will send the frame again")
	}
}
