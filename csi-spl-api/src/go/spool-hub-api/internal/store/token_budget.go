package store

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/jackc/pgx/v5"
)

// Token budgets (specs/121 section 7, T304) over rdb 0171's token_budgets.
// The hub reads, before it dispatches an agent turn, every budget that
// covers the turn (the workspace's, and its channel's) with what the ledger
// (usage_events, T302) holds against each of its limits: tokens today and
// this month (UTC), and the priced spend since the last top-up. The ledger
// is the only source: a turn not yet written counts nothing, an unmetered
// turn counts nothing (it alerts on its own, T302), and what the check reads
// is what the 8.1 credits counter shows. The one 80 % notice is a stamp on
// the budget (low_notice_at), claimed once per window of the limit that
// crossed it.
//
// A visitor budget (visitor_id) is not read here: a visitor's post never
// dispatches through this check (T305 owns the visitor spend cap). Memory
// holds no budgets: its ledger keeps no time or channel per row.

// The limits of one budget, by their rdb 0171 column.
const (
	BudgetTokensPerDay   = "tokens_per_day"
	BudgetTokensPerMonth = "tokens_per_month"
	BudgetTopup          = "topup_micros"
)

// TokenBudget is one token_budgets row. ChannelID "" = the workspace's
// budget. A nil limit is not set; TopupCurrency and ToppedUpAt are set with
// TopupMicros (rdb 0171's CHECK). Soft is NOT hard_stop, so the zero
// value is the default hard stop. LowNoticeAt zero = never noticed.
type TokenBudget struct {
	ID             int64
	ChannelID      string
	TokensPerDay   *int64
	TokensPerMonth *int64
	TopupMicros    *int64
	TopupCurrency  string
	ToppedUpAt     time.Time
	Soft           bool
	LowNoticeAt    time.Time
}

// BudgetUse is a budget with what the ledger holds against it at At:
// tokens (every llm_tokens_* kind) since the UTC day and month began, and
// the priced spend in TopupCurrency since ToppedUpAt (exact decimal micros).
// OtherCurrency counts the priced rows since the top-up in another
// currency: spend the balance cannot price, so the balance reads spent.
type BudgetUse struct {
	TokenBudget
	At            time.Time
	DayTokens     int64
	MonthTokens   int64
	SpentMicros   string
	OtherCurrency int64
}

// BudgetLevel is one limit of a budget: Used of Of, in the window that
// began at Since.
type BudgetLevel struct {
	Limit string
	Used  *big.Rat
	Of    int64
	Since time.Time
}

// Reached reports whether Used is at least pct % of Of. A limit of 0 is
// always reached: a zero budget allows no turn.
func (l BudgetLevel) Reached(pct int64) bool {
	return new(big.Rat).Mul(l.Used, big.NewRat(100, 1)).Cmp(big.NewRat(l.Of*pct, 1)) >= 0
}

// Pct is Used as a whole percent of Of, rounded down (100 for a 0 limit).
func (l BudgetLevel) Pct() int64 {
	if l.Of <= 0 {
		return 100
	}
	q := new(big.Rat).Quo(new(big.Rat).Mul(l.Used, big.NewRat(100, 1)), big.NewRat(l.Of, 1))
	return new(big.Int).Quo(q.Num(), q.Denom()).Int64()
}

// Levels is every limit u sets, in a fixed order: day, month, top-up.
func (u BudgetUse) Levels() []BudgetLevel {
	var out []BudgetLevel
	day, month := BudgetWindows(u.At)
	if u.TokensPerDay != nil {
		out = append(out, BudgetLevel{BudgetTokensPerDay, big.NewRat(u.DayTokens, 1), *u.TokensPerDay, day})
	}
	if u.TokensPerMonth != nil {
		out = append(out, BudgetLevel{BudgetTokensPerMonth, big.NewRat(u.MonthTokens, 1), *u.TokensPerMonth, month})
	}
	if u.TopupMicros != nil {
		spent, ok := new(big.Rat).SetString(u.SpentMicros)
		if !ok || u.OtherCurrency > 0 {
			// Spend the balance cannot price reads as the whole balance:
			// fail closed, never uncapped.
			spent = big.NewRat(*u.TopupMicros, 1)
		}
		out = append(out, BudgetLevel{BudgetTopup, spent, *u.TopupMicros, u.ToppedUpAt})
	}
	return out
}

// BudgetWindows is the start of the UTC day and month at.
func BudgetWindows(at time.Time) (day, month time.Time) {
	at = at.UTC()
	return time.Date(at.Year(), at.Month(), at.Day(), 0, 0, 0, 0, time.UTC),
		time.Date(at.Year(), at.Month(), 1, 0, 0, 0, 0, time.UTC)
}

// TokenBudgets is the store half of the budget check. Optional: a store
// without it holds no budgets, and the hub checks none.
type TokenBudgets interface {
	// BudgetUses is every budget covering a turn in channel ("" = none:
	// the workspace's only), with its use at at.
	BudgetUses(ctx context.Context, tenant, channel string, at time.Time) ([]BudgetUse, error)
	// ClaimBudgetNotice stamps budget id's 80 % notice at at, unless it was
	// already stamped at or after since (the window that crossed it).
	// true = this caller sends the one notice.
	ClaimBudgetNotice(ctx context.Context, tenant string, id int64, since, at time.Time) (bool, error)
	// PutTokenBudget writes the budget of b's scope (one per scope) and
	// answers its id. The notice stamp is kept.
	PutTokenBudget(ctx context.Context, tenant string, b TokenBudget) (int64, error)
}

var _ TokenBudgets = (*Postgres)(nil)

// checkTokenBudget is the Go side of rdb 0171's CHECKs on a budget.
func checkTokenBudget(b TokenBudget) error {
	if b.TokensPerDay == nil && b.TokensPerMonth == nil && b.TopupMicros == nil {
		return fmt.Errorf("token budget: set a daily, monthly or prepaid limit")
	}
	for _, n := range []*int64{b.TokensPerDay, b.TokensPerMonth, b.TopupMicros} {
		if n != nil && *n < 0 {
			return fmt.Errorf("token budget: a limit is negative")
		}
	}
	if b.TopupMicros != nil && (b.TopupCurrency == "" || b.ToppedUpAt.IsZero()) {
		return fmt.Errorf("token budget: a top-up names its currency and time")
	}
	if len(b.ChannelID) > 200 {
		return fmt.Errorf("token budget: channel id too long")
	}
	return nil
}

const (
	budgetReadSQL = `SELECT id, coalesce(channel_id, ''), tokens_per_day, tokens_per_month, topup_micros,
		coalesce(topup_currency, ''), topped_up_at, hard_stop, low_notice_at
		FROM token_budgets WHERE tenant_id = $1 AND visitor_id IS NULL
		AND (channel_id IS NULL OR channel_id = NULLIF($2, ''))
		ORDER BY channel_id NULLS FIRST`
	// One read of the ledger per budget, from the earliest window it needs
	// (usage_events_tenant_at). $2 '' = every channel of the workspace.
	budgetUseSQL = `SELECT
		coalesce(sum(units) FILTER (WHERE kind LIKE 'llm\_%' AND at >= $3), 0)::bigint,
		coalesce(sum(units) FILTER (WHERE kind LIKE 'llm\_%' AND at >= $4), 0)::bigint,
		coalesce(sum(units * unit_cost_micros) FILTER (WHERE $5::timestamptz IS NOT NULL AND at >= $5 AND currency = $6), 0)::text,
		count(*) FILTER (WHERE $5::timestamptz IS NOT NULL AND at >= $5 AND currency IS NOT NULL AND currency <> $6)
		FROM usage_events WHERE tenant_id = $1 AND ($2 = '' OR channel_id = $2)
		AND at >= least($4::timestamptz, coalesce($5::timestamptz, $4::timestamptz)) AND at <= $7`
	budgetClaimSQL = `UPDATE token_budgets SET low_notice_at = $3, updated_at = $3
		WHERE tenant_id = $1 AND id = $2 AND (low_notice_at IS NULL OR low_notice_at < $4) RETURNING id`
	budgetPutSQL = `INSERT INTO token_budgets (tenant_id, channel_id, tokens_per_day, tokens_per_month,
		topup_micros, topup_currency, topped_up_at, hard_stop)
		VALUES ($1, NULLIF($2, ''), $3, $4, $5, NULLIF($6, ''), $7, $8)
		ON CONFLICT (tenant_id, channel_id, visitor_id) DO UPDATE SET tokens_per_day = EXCLUDED.tokens_per_day,
		tokens_per_month = EXCLUDED.tokens_per_month, topup_micros = EXCLUDED.topup_micros,
		topup_currency = EXCLUDED.topup_currency, topped_up_at = EXCLUDED.topped_up_at,
		hard_stop = EXCLUDED.hard_stop, updated_at = now()
		RETURNING id`
)

func (s *Postgres) BudgetUses(ctx context.Context, tenant, channel string, at time.Time) ([]BudgetUse, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	at = at.UTC()
	day, month := BudgetWindows(at)
	var out []BudgetUse
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, budgetReadSQL, tenant, channel)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (BudgetUse, error) {
			u := BudgetUse{At: at}
			var topAt, notice *time.Time
			var hard bool
			err := r.Scan(&u.ID, &u.ChannelID, &u.TokensPerDay, &u.TokensPerMonth, &u.TopupMicros,
				&u.TopupCurrency, &topAt, &hard, &notice)
			u.Soft = !hard
			if topAt != nil {
				u.ToppedUpAt = topAt.UTC()
			}
			if notice != nil {
				u.LowNoticeAt = notice.UTC()
			}
			return u, err
		})
		if err != nil {
			return err
		}
		for i := range out {
			u := &out[i]
			var since *time.Time
			if u.TopupMicros != nil {
				since = &u.ToppedUpAt
			}
			if err := tx.QueryRow(ctx, budgetUseSQL, tenant, u.ChannelID, day, month, since, u.TopupCurrency, at).
				Scan(&u.DayTokens, &u.MonthTokens, &u.SpentMicros, &u.OtherCurrency); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Postgres) ClaimBudgetNotice(ctx context.Context, tenant string, id int64, since, at time.Time) (bool, error) {
	var got int64
	err := s.queryRowTenant(ctx, tenant, budgetClaimSQL, []any{tenant, id, at.UTC(), since.UTC()}, &got)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return err == nil, err
}

func (s *Postgres) PutTokenBudget(ctx context.Context, tenant string, b TokenBudget) (int64, error) {
	if err := checkTenant(tenant); err != nil {
		return 0, err
	}
	if err := checkTokenBudget(b); err != nil {
		return 0, err
	}
	var topAt *time.Time
	if b.TopupMicros != nil {
		t := b.ToppedUpAt.UTC()
		topAt = &t
	}
	var id int64
	err := s.queryRowTenant(ctx, tenant, budgetPutSQL, []any{tenant, b.ChannelID, b.TokensPerDay, b.TokensPerMonth,
		b.TopupMicros, b.TopupCurrency, topAt, !b.Soft}, &id)
	return id, err
}
