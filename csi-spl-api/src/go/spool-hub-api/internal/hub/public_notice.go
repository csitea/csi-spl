package hub

import (
	"context"
	"encoding/json"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The #public notice (rdb 0173; owner, 2026-10-10, msg 69e2d25f): every
// tenant's #public opens with ONE hub message saying everything in it is
// public and visible to the whole internet. The hub posts it because only the
// hub holds the box-wui key; a SQL row could not be signed. It runs once at
// start, on every retention sweep (a tenant made by `spool hub tenant-create`
// or the self-serve signup has it within one sweep) and right after the
// operator create route. store.PublicNoticeID fixes its msg_id per tenant,
// so a second post is a no-op insert.

// PublicNoticeFrom is the notice's author: the hub itself, not a member.
const PublicNoticeFrom = "HUB-0"

// PostPublicNotices posts the notice into every tenant that lacks it, and
// answers how many it stored.
func (s *Server) PostPublicNotices(ctx context.Context) int {
	pn, ok := s.o.Store.(store.PublicNotices)
	if !ok || len(s.o.WUIKey) == 0 {
		return 0
	}
	ids, err := pn.TenantsMissingPublicNotice(ctx)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("public notice: tenant list")
		return 0
	}
	n := 0
	for _, t := range ids {
		if ok, err := s.postPublicNotice(ctx, t); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", t).Msg("public notice")
		} else if ok {
			n++
		}
	}
	if n > 0 {
		s.o.Log.Info().Int("posted", n).Msg("public notice")
	}
	return n
}

// postPublicNotice stores tenant's notice, signed as box-wui, to every
// member of #public. It reports whether this call wrote it.
func (s *Server) postPublicNotice(ctx context.Context, tenant string) (bool, error) {
	if len(s.o.WUIKey) == 0 {
		return false, nil
	}
	id := store.PublicNoticeID(tenant)
	now := s.o.Now().UTC().Truncate(time.Second)
	m := &msg.Message{V: 1, MsgID: id, TaskID: id, TS: now.Format(time.RFC3339), From: PublicNoticeFrom,
		To: BroadcastID, Kind: "note", Body: store.PublicNoticeBody, Files: []msg.Attachment{}}
	env, err := wire.NewEnvelopeIn(s.o.WUIKey, WUIBox, WUIBox, store.ChannelPublicID, "", m)
	if err != nil {
		return false, err
	}
	canon, err := env.Marshal()
	if err != nil {
		return false, err
	}
	files, _ := json.Marshal(m.Files)
	row := store.Message{
		TenantID: tenant, MsgID: id, TaskID: id, TS: now,
		FromBox: WUIBox, FromID: m.From, ToBox: WUIBox, ToID: m.To, Kind: m.Kind, Body: m.Body,
		Files: files, Msg: env.Msg, EnvSig: env.Sig, Env: canon, Channel: store.ChannelPublicID,
		ReceivedAt: s.o.Now().Truncate(time.Microsecond), ExpiresAt: store.PublicNoticeExpires, IsParent: 1,
	}
	inserted, sentInOne, err := s.insertRow(ctx, row)
	if err != nil {
		return false, err
	}
	if inserted && !sentInOne {
		if err := s.o.Store.Enqueue(ctx, tenant, id, WUIBox, row.ReceivedAt, row.ReceivedAt.Add(s.o.QueueTTL), s.o.QueueMaxPerBox); err != nil {
			return true, err
		}
	}
	if inserted {
		s.fanoutWUI(ctx, row)
	}
	return inserted, nil
}
