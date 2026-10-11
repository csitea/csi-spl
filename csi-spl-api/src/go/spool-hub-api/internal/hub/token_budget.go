package hub

import (
	"context"
	"errors"
	"net/http"
	"strconv"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Token budgets (specs/121 section 7, T304). Before the hub builds an agent
// turn (an @agent dispatch or a channel fan-out of a browser send) it reads
// every budget covering the turn - the workspace's and its channel's
// (store.TokenBudgets, rdb 0171) - against the metering ledger (T302). A
// budget at 100 % of any of its limits refuses the turn 429 token_quota
// BEFORE the message is stored: no delivery, no seat, no usage row. Hard
// stop is the default; a budget the owner made soft (hard_stop false) lets
// the turn through and logs it as overage. At 80 % the workspace's
// billing.manage holders (biz_owner) get ONE notice per window of the limit
// that crossed it: the `token_budget` frame on their open sockets, and the
// log line `alert=token_budget_low` an alert policy matches on. The stamp
// (low_notice_at) is claimed in the store, so two hub processes send it once.

// Budget thresholds, in percent of a limit.
const (
	budgetNoticePct = 80
	budgetStopPct   = 100
)

// alertBudgetLow is the log field value of the 80 % notice.
const alertBudgetLow = "token_budget_low"

// tokenBudget checks the agent turn msgID of tenant in channel ("" = no
// channel) as the (token, status, detail) triple of the hub's checks: "" =
// go on. A resend of a stored msgID is no new turn. A store without budgets
// has none to check; a store that holds them and cannot read them refuses
// the turn rather than leaving the spend uncapped.
func (s *Server) tokenBudget(ctx context.Context, tenant, channel, msgID string) (string, int, string) {
	tb, ok := s.o.Store.(store.TokenBudgets)
	if !ok {
		return "", 0, ""
	}
	switch _, _, err := s.o.Store.MessageTimes(ctx, tenant, msgID); {
	case err == nil:
		return "", 0, ""
	case !errors.Is(err, store.ErrNotFound):
		return "internal", http.StatusInternalServerError, "message lookup failed"
	}
	log := s.o.Log.With().Str("tenant", tenant).Str("channel", channel).Str("msg_id", msgID).Logger()
	uses, err := tb.BudgetUses(ctx, tenant, channel, s.o.Now())
	if err != nil {
		log.Error().Err(err).Msg("token budget read")
		return "internal", http.StatusInternalServerError, "token budget unavailable"
	}
	refuse := ""
	for _, u := range uses {
		s.budgetNotice(ctx, tb, tenant, u)
		for _, l := range u.Levels() {
			if !l.Reached(budgetStopPct) {
				continue
			}
			if u.Soft {
				log.Info().Int64("budget", u.ID).Str("limit", l.Limit).Int64("pct", l.Pct()).Msg("token budget: soft limit passed, turn dispatched")
				continue
			}
			if refuse == "" {
				log.Info().Int64("budget", u.ID).Str("limit", l.Limit).Int64("pct", l.Pct()).Msg("token budget: turn refused")
				refuse = budgetScope(u) + " " + l.Limit + " budget is spent"
			}
		}
	}
	if refuse != "" {
		return "token_quota", http.StatusTooManyRequests, refuse
	}
	return "", 0, ""
}

// budgetScope names u's scope in a refusal or notice.
func budgetScope(u store.BudgetUse) string {
	if u.ChannelID != "" {
		return "the channel's"
	}
	return "the workspace's"
}

// budgetNotice sends u's one 80 % notice when a limit reached it and the
// stamp is free for that limit's window. Never fails the turn.
func (s *Server) budgetNotice(ctx context.Context, tb store.TokenBudgets, tenant string, u store.BudgetUse) {
	var hit *store.BudgetLevel
	for _, l := range u.Levels() {
		if l.Reached(budgetNoticePct) && (hit == nil || l.Since.After(hit.Since)) {
			hit = &l
		}
	}
	if hit == nil || (!u.LowNoticeAt.IsZero() && !u.LowNoticeAt.Before(hit.Since)) {
		return
	}
	log := s.o.Log.With().Str("tenant", tenant).Int64("budget", u.ID).Str("channel", u.ChannelID).
		Str("limit", hit.Limit).Int64("pct", hit.Pct()).Logger()
	claimed, err := tb.ClaimBudgetNotice(ctx, tenant, u.ID, hit.Since, s.o.Now())
	if err != nil {
		log.Error().Err(err).Msg("token budget: notice stamp")
		return
	}
	if !claimed {
		return
	}
	frame := map[string]any{"type": "token_budget", "level": "low", "scope": budgetScope(u),
		"channel": u.ChannelID, "limit": hit.Limit, "pct": hit.Pct(), "hard_stop": !u.Soft}
	sent := 0
	for member, conns := range s.flowSockets(tenant) {
		if !s.allowed(ctx, member, tenant, rbac.BillingManage) {
			continue
		}
		for _, c := range conns {
			if c.write(ctx, frame) == nil {
				sent++
			}
		}
	}
	log.Warn().Str("alert", alertBudgetLow).Int("sockets", sent).
		Msg("token budget: " + budgetScope(u) + " " + hit.Limit + " at " + strconv.FormatInt(hit.Pct(), 10) + " %")
}
