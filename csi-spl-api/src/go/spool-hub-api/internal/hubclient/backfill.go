package hubclient

import (
	"context"
	"fmt"
	"slices"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/notify"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Box side of the channel back-fill (SPL-987, specs/038 FR-020..026; the hub
// side is internal/hub/backfill.go). An agent newly seated in a channel gets
// that channel's recent posts as recv frames flagged Backfill, then one
// backfill_end. Each post lands in the agent's inbox like any delivery, but
// without its own poke; backfill_end rings the pane ONCE with a summary:
// "added to #<channel>: <k> earlier messages in <t> topics, newest from <who>".

// generalAlias is the one channel alias the hub folds (store.NormalizeChannel).
const generalAlias, lobbyChannel = "general", "lobby"

func normChannel(c string) string {
	if c == generalAlias {
		return lobbyChannel
	}
	return c
}

// receiveBackfill verifies one back-fill frame and writes it, quietly, into
// the inbox of every listed agent this box hosts - and ONLY those: msg.to is
// not added, since the post was not addressed to anyone here when it was
// made. The envelope must carry the back-filled channel as its SIGNED tag
// (channels-v1 §4.5): the hub cannot pass a DM off as a channel post.
func (s *Session) receiveBackfill(ctx context.Context, raw []byte, agents []string, channel string) error {
	e, err := wire.ParseEnvelope(raw)
	if err != nil {
		return err
	}
	if e.Channel == "" || normChannel(e.Channel) != normChannel(channel) {
		return fmt.Errorf("back-fill frame for #%s carries an envelope tagged %q", channel, e.Channel)
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
		return fmt.Errorf("back-fill frame for agents %v hosts none of them at box %q", agents, s.box)
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
	if e.FromBox == wuiBox && m.Kind != "task" && m.Kind != "note" {
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
		if wrote {
			s.mu.Lock()
			s.delivered++
			if s.backfilled == nil {
				s.backfilled = map[[2]string]int{}
			}
			s.backfilled[[2]string{normChannel(channel), id}]++
			s.mu.Unlock()
		}
	}
	return nil
}

// backfillEnd rings each listed local agent once, when its run wrote at least
// one file (a repeat run that found every post already in the inbox stays
// silent).
func (s *Session) backfillEnd(f wire.Frame) {
	ch := normChannel(f.Backfill)
	for _, id := range f.Agents {
		k := [2]string{ch, id}
		s.mu.Lock()
		wrote := s.backfilled[k]
		delete(s.backfilled, k)
		s.mu.Unlock()
		if wrote == 0 || !msg.ValidID(id) {
			continue
		}
		notify.Deliver(s.c.Cfg, BackfillSummary(f, id), id)
	}
}

// BackfillSummary is the one poke a back-fill run rings: kind note, from the
// newest post's author, on the newest post's topic, so the pane's line points
// at where the conversation is.
func BackfillSummary(f wire.Frame, to string) *msg.Message {
	from := f.From
	if from == "" {
		from = "?"
	}
	return &msg.Message{
		V: msg.V1, MsgID: f.MsgID, TaskID: f.TaskID, From: from, To: to, Kind: "note",
		Body: fmt.Sprintf("added to #%s: %d earlier %s in %d %s, newest from %s",
			normChannel(f.Backfill), f.Count, plural(f.Count, "message", "messages"),
			f.Topics, plural(f.Topics, "topic", "topics"), from),
	}
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}
