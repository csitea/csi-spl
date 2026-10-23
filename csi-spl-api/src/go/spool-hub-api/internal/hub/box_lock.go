package hub

import (
	"context"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The box owner lock at the queue points (spec 025 box-owner-lock.md section
// 5.2, row B3, SPL-2970). A locked box's agents are reached only by the
// lock's owners: every point that queues a message to a box asks this file
// first. B1's store answers the lock (5 s cache, verified on load); a
// tampered lock has no owner and no peer, so everyone is refused.
//
// The queue points and the paths of section 5.1 they cover:
//
//   - dispatchCheck (dispatch.go): a member's DM or "@agent do x" (path 2),
//     the reply in an agent's topic (2b, topic_reply.go) and the reply
//     re-routed off a retired seat (2c, retired_reply.go). It runs before
//     the sender allow-lists, so no list edit widens it.
//   - the routeChannel loop (channels.go): a channel post fanned out to
//     member agents (path 1), a bare @mention, which reaches a box only as
//     that fan-out (3), the operator replay of unsigned posts (10,
//     replay_unsigned.go) and another box's agent posting in the channel
//     (12b). The post still lands for everyone else.
//   - fallbackPick (fallback.go): a locked box is never a fallback candidate
//     for a non-owner's post (1b).
//   - handleAddChannelAgent (channel_members.go) refuses a non-owner's invite
//     of a locked-box agent, and backfillSeat (backfill.go) leaves out every
//     earlier post the fan-out would not have delivered (1c).
//
// NOT covered yet: path 12, a box's agent sending straight to a locked-box
// agent. onSend's refusal chain lives in ws.go (row B2's file), so
// boxSendLockRefusal is ready and tested but not called; its one call in
// onSend is left for batch 3.

// Audit paths of the queue points (box_lock_audit.path).
const (
	boxLockPathDispatch     = "dispatch"
	boxLockPathChannel      = "channel_fanout"
	boxLockPathBoxChannel   = "box_channel"
	boxLockPathChannelAgent = "channel_agent_add"
	boxLockPathBoxSend      = "box_send"
)

// Refusal codes and details. A detail never names an owner (5.2).
const (
	codeBoxLocked       = "box_locked"
	codeBoxLockStore    = "store_unavailable"
	boxLockedDetail     = "this box's agents are reachable only by its lock's owners"
	boxLockedPeerDetail = "this box takes messages only from the boxes its lock lists"
	boxLockStoreDetail  = "the box lock could not be read; refused"
)

// boxLock is the box's verified lock: nil for an unlocked box, a store
// without locks, the browser box or no box. An error means refuse (5.2).
func (s *Server) boxLock(ctx context.Context, tenant, box string) (*store.BoxLock, error) {
	ls, ok := s.o.Store.(store.BoxLockStore)
	if !ok || box == "" || box == WUIBox {
		return nil, nil
	}
	l, err := ls.BoxLock(ctx, tenant, box)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("box", box).Msg("box lock read")
	}
	return l, err
}

// boxLockRefusal answers nil when human hum may reach box (no lock, or hum
// is an owner); else it writes (or bumps) one refused audit row for path
// and answers 403 box_locked. A read error refuses with 503.
func (s *Server) boxLockRefusal(ctx context.Context, tenant, box, hum, path string) *frameRefusal {
	l, err := s.boxLock(ctx, tenant, box)
	if err != nil {
		return &frameRefusal{codeBoxLockStore, http.StatusServiceUnavailable, boxLockStoreDetail}
	}
	if l == nil || l.IsOwner(hum) {
		return nil
	}
	s.lockRefused(ctx, tenant, box, hum, "", path)
	return &frameRefusal{codeBoxLocked, http.StatusForbidden, boxLockedDetail}
}

// boxSendLockRefusal is path 12: a box's own send to an agent on a locked
// box passes only from the locked box itself or a peer box of its lock
// (OQ-2). NOT CALLED YET: its call belongs in onSend (ws.go), batch 3.
func (s *Server) boxSendLockRefusal(ctx context.Context, x *session, env *wire.Envelope, _ *msg.Message) *frameRefusal {
	l, err := s.boxLock(ctx, x.tenant, env.ToBox)
	if err != nil {
		return &frameRefusal{codeBoxLockStore, http.StatusServiceUnavailable, boxLockStoreDetail}
	}
	if lockAdmitsBox(l, env.FromBox) {
		return nil
	}
	s.lockRefused(ctx, x.tenant, env.ToBox, "", env.FromBox, boxLockPathBoxSend)
	return &frameRefusal{codeBoxLocked, http.StatusForbidden, boxLockedPeerDetail}
}

// lockAdmitsBox: an unlocked box, the locked box's own send, or a peer box.
func lockAdmitsBox(l *store.BoxLock, from string) bool {
	return l == nil || (!l.Tampered && from == l.BoxID) || l.IsPeer(from)
}

// lockAdmits reports whether l lets a stored post reach its box, and the
// audit path, human and from_box of a refusal. A browser post (box-wui) is
// a member's: its from is the poster's HUM-* (wuiHello sets c.from to the
// member, and only a member socket fans out or is replayed), so an owner's
// post passes. Any other post is a box's and passes from the locked box
// itself or a peer box (12b).
func lockAdmits(l *store.BoxLock, fromBox, fromID string) (ok bool, path, hum, box string) {
	switch {
	case l == nil:
		return true, "", "", ""
	case fromBox == WUIBox:
		return l.IsOwner(fromID), boxLockPathChannel, fromID, ""
	default:
		return lockAdmitsBox(l, fromBox), boxLockPathBoxChannel, "", fromBox
	}
}

// channelLockSkip is the routeChannel loop's check (paths 1, 3, 10, 12b):
// true = do not queue the post to box. A refusal is audited; a read error
// skips the box (fail closed).
func (s *Server) channelLockSkip(ctx context.Context, tenant, box string, env *wire.Envelope, m *msg.Message) bool {
	l, err := s.boxLock(ctx, tenant, box)
	if err != nil {
		return true
	}
	ok, path, hum, from := lockAdmits(l, env.FromBox, m.From)
	if !ok {
		s.lockRefused(ctx, tenant, box, hum, from, path)
	}
	return !ok
}

// fallbackLockSkip is fallbackPick's check (path 1b): a locked box is no
// candidate for hum's post. Not a refusal of anything hum asked for (the
// post lands and another box may answer), so it writes no audit row; a
// read error skips the box (fail closed).
func (s *Server) fallbackLockSkip(ctx context.Context, tenant, box, hum string) bool {
	l, err := s.boxLock(ctx, tenant, box)
	return err != nil || (l != nil && !l.IsOwner(hum))
}

// lockRefused writes (or bumps) one refused audit row (6.3). A failed
// write is logged; the refusal stands.
func (s *Server) lockRefused(ctx context.Context, tenant, box, hum, fromBox, path string) {
	ls, ok := s.o.Store.(store.BoxLockStore)
	if !ok {
		return
	}
	a := store.BoxLockAudit{TenantID: tenant, BoxID: box, HumanID: hum, FromBox: fromBox, Path: path, Verdict: store.BoxLockRefused}
	if err := ls.RecordBoxLockAudit(ctx, a, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("box", box).Str("path", path).Msg("box lock audit: refused")
	}
}
