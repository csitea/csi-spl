package hubclient

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/notify"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Box side of the fallback responder (SPL-997, specs/038 FR-030..038; the
// hub side is internal/hub/fallback.go). A human post that no agent it was
// meant for could hear arrives flagged Fallback ("#<channel>" or "DM to
// <agent>") for ONE agent of this box. It lands in that agent's inbox
// without the ordinary poke, and the pane is rung once with
// "unanswered post in <where> (...): <excerpt>" so the agent knows why a post
// that was not addressed to it is there, and answers or routes it.

// fallbackExcerpt is how many characters of the post the poke line carries.
const fallbackExcerpt = 160

// receiveFallback verifies one fallback frame and writes the post into the
// listed agents' inboxes - only agents this box hosts, never msg.to. Only a
// HUMAN post falls back, and every human post is signed by box-wui, so an
// envelope from any other box is refused: the hub cannot use this door to
// pass one agent's DM to another.
func (s *Session) receiveFallback(ctx context.Context, raw []byte, agents []string, where string) error {
	e, err := wire.ParseEnvelope(raw)
	if err != nil {
		return err
	}
	if e.FromBox != wuiBox {
		return fmt.Errorf("fallback frame carries an envelope from %q, not %s", e.FromBox, wuiBox)
	}
	local, err := s.c.scanAgents()
	if err != nil {
		return err
	}
	var targets []string
	for _, a := range agents {
		if slices.Contains(local, a) {
			targets = append(targets, a)
		}
	}
	if len(targets) == 0 {
		return fmt.Errorf("fallback frame for agents %v hosts none of them at box %q", agents, s.box)
	}
	pub, err := sign.LoadPin(s.c.Cfg.PinsDir, e.FromBox)
	if err != nil {
		return fmt.Errorf("sender box %s: %w", e.FromBox, err)
	}
	if err := e.Verify(pub); err != nil {
		return fmt.Errorf("envelope from %s: %w", e.FromBox, err)
	}
	m, err := e.Inner()
	if err != nil {
		return err
	}
	if m.Kind != "task" && m.Kind != "note" {
		return fmt.Errorf("envelope from %s with kind %q: %w", wuiBox, m.Kind, sign.ErrVerify)
	}
	for _, a := range m.Files {
		if a.Mode == "blob" {
			if err := s.fetchFile(ctx, a.FileID); err != nil {
				s.c.Log.Warn().Err(err).Str("file_id", a.FileID).Msg("attachment not fetched")
			}
		}
	}
	for _, id := range targets {
		wrote, err := spool.New(s.c.Cfg).DeliverQuiet(m, id)
		if err != nil {
			return err
		}
		if !wrote { // already in the inbox: it was rung then
			continue
		}
		s.mu.Lock()
		s.delivered++
		s.mu.Unlock()
		notify.Deliver(s.c.Cfg, FallbackPoke(m, where, id), id)
	}
	return nil
}

// FallbackPoke is the one line a fallback delivery rings: from the post's
// author, on its topic and id, so the pane's reply lands in that thread.
func FallbackPoke(m *msg.Message, where, to string) *msg.Message {
	why := "no member agent online"
	if strings.HasPrefix(where, "DM to ") {
		why = "agent offline"
	}
	return &msg.Message{
		V: msg.V1, MsgID: m.MsgID, TaskID: m.TaskID, From: m.From, To: to, Kind: m.Kind,
		Body: fmt.Sprintf("unanswered post in %s (%s): %s", where, why, excerpt(m.Body, fallbackExcerpt)),
	}
}

// excerpt is body on one line, cut to n runes with an ellipsis.
func excerpt(body string, n int) string {
	b := strings.Join(strings.Fields(body), " ")
	if utf8.RuneCountInString(b) <= n {
		return b
	}
	r := []rune(b)
	return string(r[:n]) + "…"
}
