package hub

import (
	"context"
	"errors"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The hub pins its own box-wui key (spec 158 10.6, row P1, SPL-5019). A
// workspace made by the operator create route had no box-wui pin, so no
// browser post reached its boxes until someone pinned it with the root key.
// The hub now writes that pin itself, with no root signature (the change to
// spec 014 contract 2.2): the key is only ever the hub's own loaded key (no
// key input), the write is never forced, and it happens only where the
// workspace has no box-wui pin row at all. A live pin of another key and a
// revoked pin stay as they are (PutPin unforced answers ErrConflict for
// both): a workspace that revoked box-wui is never re-pinned.
//
// Row P2's sweep (beside PostPublicNotices) calls ensureWUIPin for every
// workspace lacking the row, with its own wuiPinActor.

// box_wui_pin statuses: the create's 201 body {"box_wui_pin":{"status":...}}.
const (
	wuiPinPinned  = "pinned"  // this call wrote the pin, with one audit row
	wuiPinPresent = "present" // already pinned with the hub's key; nothing written
	wuiPinKept    = "kept"    // a revoked pin or another key: left as it is
	wuiPinNoKey   = "no_key"  // the hub has no box-wui key
	wuiPinFailed  = "failed"  // the write failed (logged); the caller goes on
)

// wuiPinActor is who the audit row of a pin names: the operator admin for
// the create route.
type wuiPinActor struct{ tenant, hum string }

// ensureWUIPin pins the hub's box-wui key in tenant when tenant has no
// box-wui pin row, and answers a box_wui_pin status. It never fails its
// caller: a failed write is logged and answered as "failed".
func (s *Server) ensureWUIPin(ctx context.Context, tenant string, by wuiPinActor) string {
	pub := s.wuiPub()
	if pub == nil {
		return wuiPinNoKey
	}
	if cur, err := s.o.Store.GetPin(ctx, tenant, WUIBox); err == nil && cur.Equal(pub) {
		return wuiPinPresent
	}
	now := s.o.Now().UTC()
	err := s.o.Store.PutPin(ctx, tenant, WUIBox, pub, false, now, now)
	switch {
	case errors.Is(err, store.ErrConflict):
		return wuiPinKept
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("box_wui_pin")
		return wuiPinFailed
	}
	s.wuiPinAudit(ctx, tenant, by)
	return wuiPinPinned
}

// wuiPinAudit writes the one operator_audit row of a hub-written pin. The
// action is "update" (the rdb 0319 CHECK list), the detail says what.
func (s *Server) wuiPinAudit(ctx context.Context, tenant string, by wuiPinActor) {
	ev := s.o.Log.Info()
	if ws, ok := s.o.Store.(store.OperatorWorkspaces); ok {
		if err := ws.AppendOperatorAudit(ctx, store.OperatorAudit{At: s.o.Now().UTC(), TenantID: tenant,
			ActorTenant: by.tenant, ActorHum: by.hum, Action: store.AuditUpdate,
			Detail: map[string]any{"box_wui_pin": wuiPinPinned, "box_id": WUIBox, "forced": false}}); err != nil {
			ev = s.o.Log.Error().Err(err)
		}
	}
	ev.Str("tenant", tenant).Str("by", by.hum).Msg("box_wui_pin.pinned")
}
