package hub

import (
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The operator replay of a workspace's unsigned browser posts (CLE-77876).
//
// prd 2026-10-01: csitea had never pinned box-wui, so wuiEnvelope stored every
// browser channel post UNSIGNED and routeChannel - which needs a signature a
// box will verify - built no box delivery (wui_unpinned, fallback_unsigned:
// 144 human posts from 2026-09-29 on, and leiden and pas-psf the same). The
// pin fixes the posts after it; this route delivers the ones before it.
//
// POST /v1/operator/replay-unsigned {tenant, since, dry_run}
//
// For each unsigned human channel post of the workspace received at or after
// since (at most replayMax, oldest first): sign it for box-wui exactly as
// wuiEnvelope would have (the same inner message, its channel and parent
// tags, verified against the tenant's pin), store the signed envelope in
// place of the unsigned one (only while the row is still unsigned, so a
// second replay or a second hub process is a no-op), then route it like a
// fresh post: one delivery per member box, pushed when that box is online,
// queued otherwise. A box's inbox write is idempotent per msg_id.
//
// Refused 409 wui_unpinned while the tenant's box-wui pin is not this hub's
// key: signing then would only store another envelope no box verifies.

// replayMax caps one call; a larger backlog is replayed by calling again.
const replayMax = 500

// replayWindow is the oldest since a call may name (the message retention).
const replayWindow = 30 * 24 * time.Hour

type replayResult struct {
	Tenant   string   `json:"tenant"`
	Since    string   `json:"since"`
	DryRun   bool     `json:"dry_run"`
	Found    int      `json:"found"`
	Resigned int      `json:"resigned"`
	Skipped  int      `json:"skipped"`
	Channels []string `json:"channels"`
	MsgIDs   []string `json:"msg_ids"`
}

func (s *Server) handleOperatorReplayUnsigned(w http.ResponseWriter, r *http.Request) {
	by, ok := s.operatorAuth(w, r)
	if !ok {
		return
	}
	var body struct {
		Tenant string `json:"tenant"`
		Since  string `json:"since"`
		DryRun bool   `json:"dry_run"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<10))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "body must be {tenant, since, dry_run?}")
		return
	}
	if !msg.ValidTenantID(body.Tenant) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "tenant must be a valid slug")
		return
	}
	now := s.o.Now()
	since, err := time.Parse(time.RFC3339, body.Since)
	if err != nil || since.After(now) || now.Sub(since) > replayWindow {
		writeErr(w, http.StatusBadRequest, "bad_since", "since must be an RFC 3339 time within the last 30 days")
		return
	}
	rs, ok := s.o.Store.(store.UnsignedReplay)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store cannot replay")
		return
	}
	ctx := r.Context()
	pin := s.wuiPin(ctx, body.Tenant)
	if pin == nil {
		writeErr(w, http.StatusConflict, "wui_unpinned", "the tenant's box-wui pin is not this hub's key: pin it first (do_spl_cloud_pin_box_wui)")
		return
	}
	rows, err := rs.UnsignedWUIPosts(ctx, body.Tenant, since, now, replayMax)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", body.Tenant).Msg("replay read")
		writeErr(w, http.StatusInternalServerError, "internal", "unsigned posts not read")
		return
	}
	out := replayResult{Tenant: body.Tenant, Since: since.UTC().Format(time.RFC3339), DryRun: body.DryRun,
		Found: len(rows), Channels: []string{}, MsgIDs: []string{}}
	seen := map[string]bool{}
	for _, p := range rows {
		if !seen[p.Channel] {
			seen[p.Channel] = true
			out.Channels = append(out.Channels, p.Channel)
		}
		if body.DryRun {
			out.MsgIDs = append(out.MsgIDs, p.MsgID)
			continue
		}
		if s.replayOne(r, rs, body.Tenant, pin, p) {
			out.Resigned++
			out.MsgIDs = append(out.MsgIDs, p.MsgID)
		} else {
			out.Skipped++
		}
	}
	s.o.Log.Info().Str("tenant", body.Tenant).Str("by", by).Str("since", out.Since).Bool("dry_run", body.DryRun).
		Int("found", out.Found).Int("resigned", out.Resigned).Int("skipped", out.Skipped).Msg("operator.replay_unsigned")
	writeJSON(w, http.StatusOK, out)
}

// replayOne signs, stores and routes one unsigned post; false = skipped (it
// does not parse or sign, or another call signed it first).
func (s *Server) replayOne(r *http.Request, rs store.UnsignedReplay, tenant string, pin ed25519.PublicKey, p store.UnsignedPost) bool {
	ctx := r.Context()
	log := s.o.Log.With().Str("tenant", tenant).Str("msg_id", p.MsgID).Logger()
	old, err := wire.ParseEnvelope(p.Env)
	if err != nil || old.Sig != "" || old.FromBox != WUIBox {
		log.Warn().Err(err).Msg("replay: not an unsigned box-wui envelope")
		return false
	}
	m, err := old.Inner()
	if err != nil {
		log.Warn().Err(err).Msg("replay: inner message")
		return false
	}
	channel := old.Channel
	if channel == "" {
		channel = p.Channel
	}
	env, err := s.dispatchEnvelope(WUIBox, channel, old.ParentTaskID, pin, m)
	if err != nil {
		log.Error().Err(err).Msg("replay: sign")
		return false
	}
	canon, err := env.Marshal()
	if err != nil {
		return false
	}
	won, err := rs.ResignMessage(ctx, tenant, p.MsgID, canon, env.Sig)
	if err != nil {
		log.Error().Err(err).Msg("replay: store")
		return false
	}
	if !won {
		return false
	}
	s.routeChannel(ctx, tenant, s.tagChannel(env.Channel, m.TaskID), env, m, canon)
	return true
}
