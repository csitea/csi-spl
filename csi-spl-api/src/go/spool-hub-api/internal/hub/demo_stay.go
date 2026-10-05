package hub

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The 3-hour stay (specs/077 FR-005, T009). Admission writes the seat's end
// (store.AdmitPolicy.OpenMaxStay); after it the membership grants nothing,
// and this file makes the end visible and final:
//
//   - the door: a session that signed in to the demo workspace and whose
//     demo seat ended (or was already swept) gets 401 demo_expired, where it
//     got a plain 401 view_door or 403 not_member (humanTenant);
//   - every socket frame: a demo visitor's socket checks the seat before the
//     frame is read on, writes a demo_expired error and closes 4401;
//   - the sweep, every demoSweepEvery: drops the ended seats and the
//     visitors' personal data (store.SweepDemo names the rows), closes their
//     sockets and deletes their hub-wide avatars.

// demoSweepEvery is the stay sweep's period (spec 3.6: every 5 minutes).
const demoSweepEvery = 5 * time.Minute

// demoExpiredReason is the 401 error code and the socket close reason the
// WUI reads as "your visit has ended" (T020).
const demoExpiredReason = "demo_expired"

// demoMaxStay is the configured stay, the store default when unset.
func (s *Server) demoMaxStay() time.Duration {
	if s.o.DemoMaxStay <= 0 {
		return store.DefaultDemoMaxStay
	}
	return s.o.DemoMaxStay
}

// demoStayText is the stay as GET /v1/demo shows it: "3h", "90m" -> "1h30m".
func demoStayText(d time.Duration) string {
	t := d.String()
	if strings.HasSuffix(t, "m0s") {
		t = strings.TrimSuffix(t, "0s")
	}
	if strings.HasSuffix(t, "h0m") {
		t = strings.TrimSuffix(t, "0m")
	}
	return t
}

// demoSeatEnded reports whether hum's demo seat has ended (or was swept).
// Read only on a refusal path, never on an admitted request.
func (s *Server) demoSeatEnded(ctx context.Context, hum string) bool {
	st, ok := s.o.Store.(store.DemoStays)
	if !ok || s.o.DemoWorkspace == "" || hum == "" {
		return false
	}
	ended, err := st.DemoSeatEnded(ctx, s.o.DemoWorkspace, hum, s.o.Now())
	if err != nil {
		s.o.Log.Warn().Err(err).Str("human_id", hum).Msg("demo seat read")
	}
	return err == nil && ended
}

// doorDemoExpired writes 401 demo_expired when the refused session signed in
// to the demo workspace and its seat has ended; false = not that case, the
// caller answers as before.
func (s *Server) doorDemoExpired(w http.ResponseWriter, r *http.Request) bool {
	if s.o.DemoWorkspace == "" || s.o.Auth == nil {
		return false
	}
	sess, ok := s.o.Auth.SessionFromRequest(r)
	if !ok || sess.Tenant != s.o.DemoWorkspace || !s.demoSeatEnded(r.Context(), sess.HumanID) {
		return false
	}
	writeErr(w, http.StatusUnauthorized, demoExpiredReason, "your demo visit has ended")
	return true
}

// demoFrameEnded ends a demo visitor's socket whose seat has ended: an error
// frame, then close 4401 demo_expired. Only sockets in the demo workspace
// pay the read.
func (s *Server) demoFrameEnded(ctx context.Context, c *wuiConn) bool {
	if s.o.DemoWorkspace == "" || c.tenant != s.o.DemoWorkspace || c.member == "" {
		return false
	}
	if !s.demoSeatEnded(ctx, c.member) {
		return false
	}
	c.write(ctx, wuiErr{"error", demoExpiredReason, http.StatusUnauthorized, "your demo visit has ended", ""}) //nolint:errcheck
	c.close(wire.CloseUnauthorized, demoExpiredReason)
	return true
}

// SweepDemo is one stay sweep (RunSweeper, every demoSweepEvery): the store
// drops the ended seats and the visitors' data, then their sockets close and
// their avatars go.
func (s *Server) SweepDemo(ctx context.Context) {
	st, ok := s.o.Store.(store.DemoStays)
	if !ok || s.o.DemoWorkspace == "" {
		return
	}
	out, err := st.SweepDemo(ctx, s.o.DemoWorkspace, s.demoMaxStay(), s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Msg("demo stay sweep")
		return
	}
	if len(out.Ended) == 0 {
		return
	}
	closed := s.closeMemberSockets(s.o.DemoWorkspace, out.Ended, demoExpiredReason)
	avatars := s.deleteAvatars(ctx, out.Avatars)
	s.o.Log.Info().Int("ended", len(out.Ended)).Int("humans", out.Humans).Int("rows", out.Rows).
		Int("sockets", closed).Int("avatars", avatars).Msg("demo stay sweep")
}

// closeMemberSockets closes, with 4401 reason, every browser socket of
// tenant whose member is in hums; it returns how many. Each close runs on
// its own: a close waits for the browser's close frame, and one silent
// browser must not hold the sweeper.
func (s *Server) closeMemberSockets(tenant string, hums []string, reason string) int {
	var gone []*wuiConn
	s.mu.Lock()
	for c := range s.wui {
		if c.tenant == tenant && c.member != "" && slices.Contains(hums, c.member) {
			gone = append(gone, c)
		}
	}
	s.mu.Unlock()
	for _, c := range gone {
		go c.close(wire.CloseUnauthorized, reason)
	}
	return len(gone)
}

// deleteAvatars deletes the hub-wide copies avatars/<file_id> nobody carries
// any more; it returns how many went.
func (s *Server) deleteAvatars(ctx context.Context, ids []string) int {
	n := 0
	for _, id := range ids {
		key, err := blob.AvatarKey(id)
		if err != nil || s.o.Blob == nil {
			continue
		}
		if err := s.o.Blob.Delete(ctx, key); err != nil && !errors.Is(err, blob.ErrNotFound) {
			s.o.Log.Warn().Err(err).Str("file_id", id).Msg("demo avatar delete")
			continue
		}
		n++
	}
	return n
}
