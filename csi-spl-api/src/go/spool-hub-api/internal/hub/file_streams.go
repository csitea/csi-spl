package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// File streams (spec 160 sections 3.3 and 3.7, row B2, rdb 0237; owner
// HUM-10, t1 c168784c). Box side, over the authenticated hello (the box
// follower's `spool file-streams push`); the box and the workspace are the
// session's, never the frame's (owner Q2 A: the box's own workspace):
//
//	lane_op file_streams_announce  {streams: [wire.FileStreamAnnounced]}
//	                               -> wire.FileStreamsAckFrame {type: ack, streams: [{stream_key, state, reason}]}
//	lane_op file_streams_push      {stream_key, lines, dropped, redactions}
//	                               -> wire.FileStreamsAckFrame {type: ack, stream_key, inserted, acked_seq, pruned}
//
// A refused push stores nothing (spec 160 C23): 413 too_large over 1000
// lines or the byte cap, 429 rate_limited over twice the line rate, 409
// not_announced, 403 refused for a stream refused at announce. The browser
// read routes are row B3's.

// isFileStreamsLaneOp routes a lane frame to onFileStreamsLane.
func isFileStreamsLaneOp(op string) bool { return strings.HasPrefix(op, "file_streams_") }

// onFileStreamsLane answers a file_streams lane frame. A refusal is an error
// frame on the frame's msg_id; the connection stays open.
func (s *Server) onFileStreamsLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	ack, ae := s.fileStreamsLane(ctx, x, f)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(ack)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TLane, MsgID: id, LaneOp: f.LaneOp, Lane: raw}) //nolint:errcheck
}

func (s *Server) fileStreamsLane(ctx context.Context, x *session, f wire.Frame) (*wire.FileStreamsAckFrame, *issueErr) {
	fs, ok := s.o.Store.(store.FileStreamStore)
	if !ok {
		return nil, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no file streams"}
	}
	if x.tenant == "" || !store.FleetNameRe.MatchString(x.box) {
		return nil, &issueErr{http.StatusForbidden, "forbidden", "only a pinned box session announces or pushes file streams"}
	}
	now := s.o.Now().UTC()
	switch f.LaneOp {
	case wire.FileStreamsAnnounceOp:
		return s.fileStreamsAnnounce(ctx, fs, x, f, now)
	case wire.FileStreamsPushOp:
		return s.fileStreamsPush(ctx, fs, x, f, now)
	}
	return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane_op must be " + wire.FileStreamsAnnounceOp + " or " + wire.FileStreamsPushOp}
}

func (s *Server) fileStreamsAnnounce(ctx context.Context, fs store.FileStreamStore, x *session, f wire.Frame, now time.Time) (*wire.FileStreamsAckFrame, *issueErr) {
	a, err := wire.DecodeFileStreamsAnnounce(f.Lane)
	if err != nil {
		return nil, &issueErr{http.StatusBadRequest, "bad_file_stream", err.Error()}
	}
	got, err := fs.AnnounceFileStreams(ctx, x.tenant, x.box, a.Streams, s.o.FileStreamLimits, now)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("file streams announce")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "file streams announce not stored"}
	}
	return &wire.FileStreamsAckFrame{Type: "ack", LaneOp: wire.FileStreamsAnnounceOp, Streams: got, At: now.Format(time.RFC3339)}, nil
}

func (s *Server) fileStreamsPush(ctx context.Context, fs store.FileStreamStore, x *session, f wire.Frame, now time.Time) (*wire.FileStreamsAckFrame, *issueErr) {
	p, err := wire.DecodeFileStreamsPush(f.Lane)
	switch {
	case errors.Is(err, wire.ErrFileStreamTooLarge):
		return nil, &issueErr{http.StatusRequestEntityTooLarge, "too_large", err.Error()}
	case err != nil:
		return nil, &issueErr{http.StatusBadRequest, "bad_file_stream", err.Error()}
	}
	r, err := fs.RecordFileStreamLines(ctx, x.tenant, x.box, p, s.o.FileStreamLimits, now)
	switch {
	case errors.Is(err, store.ErrFileStreamUnknown):
		return nil, &issueErr{http.StatusConflict, "not_announced", "announce the stream before its lines (file_streams_announce)"}
	case errors.Is(err, store.ErrFileStreamRefused):
		return nil, &issueErr{http.StatusForbidden, "refused", "the hub refused this stream at announce (spec 160 3.7 limits)"}
	case errors.Is(err, store.ErrFileStreamRate):
		return nil, &issueErr{http.StatusTooManyRequests, "rate_limited", "a minute of this stream is over twice its line rate; nothing stored"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("file streams push")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "file stream lines not stored"}
	}
	return &wire.FileStreamsAckFrame{Type: "ack", LaneOp: wire.FileStreamsPushOp, StreamKey: p.StreamKey,
		Inserted: r.Inserted, AckedSeq: r.AckedSeq, Pruned: r.Pruned, At: now.Format(time.RFC3339)}, nil
}

// sweepFileStreams is the file streams retention pass (spec 160 3.7, row
// B6): 7 days of lines, then each workspace within its caps.
func (s *Server) sweepFileStreams(ctx context.Context) {
	fs, ok := s.o.Store.(store.FileStreamStore)
	if !ok {
		return
	}
	r, err := fs.SweepFileStreams(ctx, s.o.Now(), s.o.FileStreamLimits)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("file streams retention sweep")
		return
	}
	if r.Expired+r.Pruned > 0 {
		s.o.Log.Info().Int("expired", r.Expired).Int("pruned", r.Pruned).Msg("file streams retention sweep")
	}
}
