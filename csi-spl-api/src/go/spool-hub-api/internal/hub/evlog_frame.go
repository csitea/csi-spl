package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/evlog"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The evlog frame (spec 162 10.4.4, SPL-5882 row T6): the box reader of
// source (b) reads its env's cursor (evlog_op cursor) and puts one window's
// error groups (evlog_op put) by compare-and-set on it. Only a box of the
// operator workspace may (else 403 operator.workspaces), and only for the
// env this hub serves: the hub of an env writes its own env's row. A put
// whose gen or from is not the stored cursor's answers 409 cursor_moved and
// writes nothing, so two boxes reading one hour count it once.

// evlogActorReader is the actor of a source (b) row (10.3).
const evlogActorReader = "cloud-logging"

// evlogSourceA are the kinds the hub writes itself: a group of one of them
// that reaches a put came from the hub's unwritten line (rule 1), so its row
// keeps the hub as actor, as the hub would have written it.
var evlogSourceA = map[string]bool{
	store.LogKindErrHTTPServer: true, store.LogKindErrPanic: true,
	store.LogKindErrLoopPanic: true, store.LogKindErrLog: true,
}

// onEvlog answers an evlog frame.
func (s *Server) onEvlog(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "an evlog frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxEvlog(ctx, x, f)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TEvlog, MsgID: id, EvlogOp: f.EvlogOp, Evlog: raw}) //nolint:errcheck
}

// boxEvlog checks who sends the frame, then reads or puts the cursor.
func (s *Server) boxEvlog(ctx context.Context, x *session, f wire.Frame) (wire.EvlogCursor, *issueErr) {
	op, err := s.operatorTenant(ctx)
	if err != nil {
		return wire.EvlogCursor{}, &issueErr{http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read"}
	}
	if op == "" || op != x.tenant {
		return wire.EvlogCursor{}, &issueErr{http.StatusForbidden, permOperatorAdmin, "an evlog frame comes only from a box of the operator workspace"}
	}
	ls, ok := s.o.Store.(store.LogEvents)
	if !ok {
		return wire.EvlogCursor{}, &issueErr{http.StatusServiceUnavailable, "unavailable", "this hub's store keeps no system log"}
	}
	var c store.EvlogCursor
	switch f.EvlogOp {
	case wire.EvlogOpCursor:
		var req wire.EvlogCursorReq
		if ae := evlogDecode(f.Evlog, &req); ae != nil {
			return wire.EvlogCursor{}, ae
		}
		if ae := s.evlogEnv(req.Env); ae != nil {
			return wire.EvlogCursor{}, ae
		}
		c, err = ls.SystemEventsCursor(ctx, req.Env)
	case wire.EvlogOpPut:
		var p store.EvlogPut
		var ae *issueErr
		if p, ae = s.evlogPut(x, f.Evlog); ae != nil {
			return wire.EvlogCursor{}, ae
		}
		c, err = ls.PutSystemErrorGroups(ctx, p)
		if errors.Is(err, store.ErrEvlogCursorMoved) {
			return wire.EvlogCursor{}, &issueErr{http.StatusConflict, "cursor_moved", "another box read this window first; nothing was written"}
		}
		if err == nil {
			s.o.Log.Info().Str("box", x.box).Str("env", p.Env).Int64("gen", c.Gen).Int("groups", len(p.Groups)).Msg("evlog put")
		}
	default:
		return wire.EvlogCursor{}, &issueErr{http.StatusBadRequest, "bad_frame", "evlog_op must be cursor or put"}
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("box", x.box).Str("op", f.EvlogOp).Msg("evlog store")
		return wire.EvlogCursor{}, &issueErr{http.StatusInternalServerError, "internal", "event log unavailable"}
	}
	return wire.EvlogCursor{Env: c.Env, ReadUntil: c.ReadUntil, Gen: c.Gen, By: c.ByActor}, nil
}

// evlogDecode reads the frame's evlog object strictly: an unknown field is
// refused, so a newer box never has a field dropped unseen.
func evlogDecode(raw json.RawMessage, v any) *issueErr {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if len(raw) == 0 || dec.Decode(v) != nil {
		return &issueErr{http.StatusBadRequest, "bad_frame", "evlog is not a valid cursor or put object"}
	}
	return nil
}

// evlogEnv refuses an env this hub does not serve.
func (s *Server) evlogEnv(env string) *issueErr {
	if env != s.o.Env || (env != "dev" && env != "prd") {
		return &issueErr{http.StatusBadRequest, "bad_frame", "env must be this hub's env (" + s.o.Env + ")"}
	}
	return nil
}

// evlogPut turns a put request into the store's put: each group's text once
// more through Redact (10.6: every text that reaches a row), the box as
// the cursor's actor. The store checks the rest (window, cap, each group).
func (s *Server) evlogPut(x *session, raw json.RawMessage) (store.EvlogPut, *issueErr) {
	var req wire.EvlogPutReq
	if ae := evlogDecode(raw, &req); ae != nil {
		return store.EvlogPut{}, ae
	}
	if ae := s.evlogEnv(req.Env); ae != nil {
		return store.EvlogPut{}, ae
	}
	if len(req.Groups) > store.EvlogPutMaxGroups || req.Gen < 0 || req.To.IsZero() || !req.To.After(req.From) {
		return store.EvlogPut{}, &issueErr{http.StatusBadRequest, "bad_frame", "a put names gen >= 0, from before to and at most 500 groups"}
	}
	p := store.EvlogPut{Env: req.Env, Gen: req.Gen, From: req.From, To: req.To, Actor: x.box,
		Groups: make([]store.LogEvent, 0, len(req.Groups))}
	for _, g := range req.Groups {
		if !strings.HasPrefix(g.Kind, "error.") && g.Kind != evlog.KindOverflow {
			return store.EvlogPut{}, &issueErr{http.StatusBadRequest, "bad_frame", "a group's kind is error.* or evlog.overflow"}
		}
		actor := evlogActorReader
		if evlogSourceA[g.Kind] {
			actor = evlogActorHub
		}
		e := store.LogEvent{At: g.LastAt, Kind: g.Kind, Level: g.Level, Actor: actor, Message: evlog.Redact(g.Message),
			Fingerprint: g.Fingerprint, FirstAt: g.FirstAt, N: g.N}
		if ref := evlog.Redact(g.OriginRef); ref != "" {
			e.OriginKind, e.OriginRef = store.LogOriginComponent, evlogCut(ref, 120)
		}
		p.Groups = append(p.Groups, e)
	}
	return p, nil
}
