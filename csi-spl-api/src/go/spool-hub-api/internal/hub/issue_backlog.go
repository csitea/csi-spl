package hub

import (
	"context"
	"encoding/json"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The "Issue backlog" discussion (rdb 0187, SPL-1593; owner HUM-10, t1
// fcf09921, msg e3c349e2, "A"): in every workspace other than t1, the
// discussion an issue links to when it has no other (the issues from before
// the rule, and an issue whose last discussion was deleted). It is a SIGNED
// message, so the hub posts it, as it posts the #public notice: one #lobby
// card under msg_id = task_id = store.IssueBacklogID(tenant), which never
// expires. PostIssueBacklogs runs at start and on every retention sweep for
// every tenant whose issues link to it while it is missing; a link to it
// made through the hub posts it at once (checkDiscussion).

// PostIssueBacklogs posts the backlog topic into every tenant that links to
// it and lacks it, and answers how many it stored.
func (s *Server) PostIssueBacklogs(ctx context.Context) int {
	d, ok := s.issueDiscussionStore()
	if !ok || len(s.o.WUIKey) == 0 {
		return 0
	}
	ids, err := d.TenantsMissingIssueBacklog(ctx)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("issue backlog: tenant list")
		return 0
	}
	n := 0
	for _, t := range ids {
		if ok, err := s.postIssueBacklog(ctx, t); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", t).Msg("issue backlog")
		} else if ok {
			n++
		}
	}
	if n > 0 {
		s.o.Log.Info().Int("posted", n).Msg("issue backlog")
	}
	return n
}

// postIssueBacklog stores tenant's backlog topic, signed as box-wui, in
// #lobby. It reports whether this call wrote it; a second call is a no-op
// insert.
func (s *Server) postIssueBacklog(ctx context.Context, tenant string) (bool, error) {
	if len(s.o.WUIKey) == 0 {
		return false, nil
	}
	id := store.IssueBacklogID(tenant)
	now := s.o.Now().UTC().Truncate(time.Second)
	m := &msg.Message{V: 1, MsgID: id, TaskID: id, TS: now.Format(time.RFC3339), From: PublicNoticeFrom,
		To: BroadcastID, Kind: "note", Body: store.IssueBacklogBody, Files: []msg.Attachment{}}
	env, err := wire.NewEnvelopeIn(s.o.WUIKey, WUIBox, WUIBox, store.ChannelLobby, "", m)
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
		Files: files, Msg: env.Msg, EnvSig: env.Sig, Env: canon, Channel: store.ChannelLobby,
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
