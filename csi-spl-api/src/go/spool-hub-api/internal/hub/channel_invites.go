package hub

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Pending channel membership (spec 025 section 11, SPL-3686, rdb 0231). The
// owner's call (t1 b602f8b4 msg 4a3ec33a): a person who has not joined the
// workspace yet can still be put in a channel. POST
// /v1/channels/{channel}/members takes {"email"} next to {"human_id"}:
//
//   - the address of a current member is the plain add (channel_humans);
//   - the address of an OPEN workspace invite gets a pending row;
//   - an address with no open invite gets one first, under the members.invite
//     rule of POST /v1/members/invites (same default role, ttl and mail), then
//     the pending row. A caller without members.invite gets that route's 403.
//
// The pending row grants nothing; accepting the invite moves it to
// channel_humans (store). Revoking the invite deletes it, so the typo the
// tenant-member check guards against still leaves nothing behind.

// addChannelInvitee answers the {"email"} add; the channel door, the owner
// rule and billing were already checked by handleAddChannelMember.
func (s *Server) addChannelInvitee(w http.ResponseWriter, r *http.Request, t store.Tenant, ch, hum, raw string) {
	email := store.NormalizeInviteEmail(raw)
	if len(email) < 3 || len(email) > 320 || !strings.Contains(email, "@") {
		writeErr(w, http.StatusBadRequest, "bad_email", "email must be an address")
		return
	}
	ci, ok := s.o.Store.(store.ChannelInvites)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "pending memberships unavailable")
		return
	}
	if id := s.memberByEmail(r.Context(), t.ID, email); id != "" {
		s.addChannelHuman(w, r, t, ch, hum, id)
		return
	}
	invite, mail := "existing", ""
	err := ci.AddChannelInvite(r.Context(), t.ID, ch, email, hum, s.o.Now())
	if errors.Is(err, store.ErrNoOpenInvite) {
		if mail, ok = s.inviteForChannel(w, r, ch, email); !ok {
			return
		}
		invite = "created"
		err = ci.AddChannelInvite(r.Context(), t.ID, ch, email, hum, s.o.Now())
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_channel", "no channel "+r.PathValue("channel")+" in this tenant")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "pending membership not stored")
		return
	}
	s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("invite", invite).
		Str("by", hum).Msg("channel member pending")
	out := map[string]any{"channel": ch, "email": email, "pending": true, "invite": invite, "added_by": hum}
	if mail != "" {
		out["mail"] = mail
	}
	writeJSON(w, http.StatusCreated, out)
}

// memberByEmail is the live member of tenant whose address is email, or "".
func (s *Server) memberByEmail(ctx context.Context, tenant, email string) string {
	d, ok := s.o.Store.(store.MemberDirectory)
	if !ok {
		return ""
	}
	ms, err := d.ListMembers(ctx, tenant)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Msg("members for channel add")
		return ""
	}
	for _, m := range ms {
		if !m.Disabled && !m.Suspended && strings.EqualFold(m.Email, email) {
			return m.HumanID
		}
	}
	return ""
}

// inviteForChannel stores (and mails) a workspace invite for email under the
// rule of POST /v1/members/invites; ok=false means it already answered.
func (s *Server) inviteForChannel(w http.ResponseWriter, r *http.Request, ch, email string) (string, bool) {
	t, a, roles, h, ok := s.membersActor(w, r, rbac.MembersInvite)
	if !ok {
		return "", false
	}
	role, ok := grantable(w, a, roles, "", store.RoleDefault)
	if !ok {
		return "", false
	}
	now := s.o.Now().UTC()
	in := store.Invite{TenantID: t.ID, Email: email, Role: role, InvitedBy: a.HumanID,
		ExpiresAt: now.Add(inviteTTLDefault), OrderedBy: a.HumanID, OrderedVia: "#" + ch}
	if err := h.PutInvite(r.Context(), in, now); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "invite not stored")
		return "", false
	}
	mailed := s.mailInvite(r, t.ID, email)
	s.o.Log.Info().Str("tenant", t.ID).Str("by", a.HumanID).Str("role", role).Str("mail", mailed).
		Str("channel", ch).Msg("member.invited")
	return mailed, true
}

// removeChannelInvitee is DELETE /v1/channels/{channel}/members/{email}: undo
// a pending add. Whoever may add (mayInviteChannel) may, and channels.manage.
func (s *Server) removeChannelInvitee(w http.ResponseWriter, r *http.Request, t store.Tenant, ch, hum, email string) {
	row, ok := s.channelRecord(w, r, t.ID, ch)
	if !ok {
		return
	}
	if !mayInviteChannel(row.CreatedBy, hum, row.MembersOpenInvite) && !s.permit(w, r, t.ID, hum, rbac.ChannelsManage) {
		return
	}
	ci, ok := s.o.Store.(store.ChannelInvites)
	if !ok {
		writeErr(w, http.StatusInternalServerError, "internal", "pending memberships unavailable")
		return
	}
	switch err := ci.RemoveChannelInvite(r.Context(), t.ID, ch, email); {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no pending invite for that address in #"+ch)
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "pending membership not removed")
	default:
		s.o.Log.Info().Str("tenant", t.ID).Str("channel", ch).Str("by", hum).Msg("channel member pending removed")
		w.WriteHeader(http.StatusNoContent)
	}
}

// channelInvitees is the open pending addresses of a created channel for the
// members list; [] on a default channel, a store without them, or an error.
func (s *Server) channelInvitees(ctx context.Context, tenant, ch string) []string {
	ci, ok := s.o.Store.(store.ChannelInvites)
	if !ok || store.ChannelPublic(ch) {
		return []string{}
	}
	out, err := ci.ChannelInvitees(ctx, tenant, ch, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", ch).Msg("pending channel members")
	}
	if out == nil {
		out = []string{}
	}
	return out
}
