package hub

import (
	"context"
	"errors"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Metering (specs/121 section 7, T302). Every recv frame names its turn, the
// delivered message's msg_id (wire.Frame.TurnID). The seat's reply names the
// turn it closes and carries the model's own usage record (wire.Frame.Usage);
// the hub then writes the turn's ledger rows, priced at write time
// (store.UsageLedger). A reply that names a turn without a usable report is
// written "unmetered" and alerts: a gap is visible, never read as zero. A
// reply that names no turn (every older box) meters nothing and is never
// refused: metering runs after the post is stored and cannot fail the send.

// alertUnmetered is the log field value an alert policy matches on.
const alertUnmetered = "usage_unmetered"

// turnLedgerID is the ledger key of agent's turn on the delivered message
// turn: a channel post delivered to several agents is one turn per agent.
func turnLedgerID(turn, agent string) string { return turn + ":" + agent }

// usageGap is why rep cannot meter turn ("" = it can).
func usageGap(turn string, rep *wire.UsageReport) string {
	switch {
	case rep == nil:
		return "no usage report"
	case rep.TurnID != turn:
		return "the usage report names another turn"
	}
	if err := rep.Check(); err != nil {
		return err.Error()
	}
	return ""
}

// meterTurn writes the ledger rows of the turn the send frame f closes,
// after agent's post replyID is stored in channel. Never fails the send.
func (s *Server) meterTurn(ctx context.Context, tenant, channel, agent, replyID string, f wire.Frame) {
	turn := f.TurnID
	if turn == "" && f.Usage != nil {
		turn = f.Usage.TurnID
	}
	ul, ok := s.o.Store.(store.UsageLedger)
	if turn == "" || !ok {
		return
	}
	log := s.o.Log.With().Str("tenant", tenant).Str("turn", turn).Str("agent", agent).Logger()
	if !uuidRe.MatchString(turn) || turn == replyID {
		log.Warn().Msg("usage: turn_id is not the msg_id of a delivered message; nothing metered")
		return
	}
	if _, _, err := s.o.Store.MessageTimes(ctx, tenant, turn); err != nil {
		// A turn the hub never delivered in this workspace is no charge.
		log.Warn().Err(err).Msg("usage: no such turn in this workspace; nothing metered")
		return
	}
	ref := store.TurnRef{TurnID: turnLedgerID(turn, agent), ChannelID: channel, AgentID: agent, At: s.o.Now()}
	gap := usageGap(turn, f.Usage)
	if gap == "" {
		u := f.Usage
		_, err := ul.MeterTurn(ctx, tenant, store.TurnUsage{TurnRef: ref, Provider: u.Provider, Model: u.Model,
			TokensIn: u.TokensIn, TokensOut: u.TokensOut, CacheRead: u.CacheRead, CacheWrite: u.CacheWrite})
		if err == nil {
			return
		}
		gap = "the report was not written: " + err.Error()
		if !errors.Is(err, store.ErrNoPrice) {
			log.Error().Err(err).Msg("usage: write the turn's rows")
		}
	}
	if _, err := ul.UnmeteredTurn(ctx, tenant, ref); err != nil {
		log.Error().Err(err).Str("alert", alertUnmetered).Str("reason", gap).Msg("usage: unmetered turn NOT written")
		return
	}
	log.Error().Str("alert", alertUnmetered).Str("reason", gap).Msg("usage: turn written unmetered")
}
