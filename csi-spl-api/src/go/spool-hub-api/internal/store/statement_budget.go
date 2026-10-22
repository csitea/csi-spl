package store

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
)

// The statement budget of a request (SPL-2866, the prd incident of
// 2026-10-22): view requests held the pool's connections for minutes, and
// sign-in, waiting for one, answered 503 after its own 10 s. A request that
// carries a budget (WithStatementTimeout; the hub's view deadline sets it)
// has it appended to the scope statement every store read opens with,
// set_config('statement_timeout', <ms>, true), so Postgres itself cancels a
// statement past it (SQLSTATE 57014) and the connection goes back to the
// pool whole. It rides in the scope statement, so it costs no round trip,
// and it is transaction-local like the scope: it ends with the batch or the
// transaction and never reaches the next pool user.

type statementBudgetKey struct{}

// WithStatementTimeout returns ctx carrying d as the server-side budget of
// each store statement under it; d <= 0 returns ctx unchanged.
func WithStatementTimeout(ctx context.Context, d time.Duration) context.Context {
	if d <= 0 {
		return ctx
	}
	return context.WithValue(ctx, statementBudgetKey{}, d)
}

// StatementTimeout is the budget WithStatementTimeout put on ctx, or 0.
func StatementTimeout(ctx context.Context) time.Duration {
	d, _ := ctx.Value(statementBudgetKey{}).(time.Duration)
	return d
}

// budgeted is scope (a `SELECT set_config(...)` list) plus ctx's statement
// budget, or scope itself when ctx carries none. The milliseconds are an
// integer formatted here, never caller text.
func budgeted(ctx context.Context, scope string) string {
	d := StatementTimeout(ctx)
	if d <= 0 {
		return scope
	}
	return scope + ", set_config('statement_timeout', '" + strconv.FormatInt(max(d.Milliseconds(), 1), 10) + "', true)"
}

// IsStatementTimeout reports whether err is Postgres cancelling a statement
// (SQLSTATE 57014, query_canceled: a statement_timeout or a cancel request).
func IsStatementTimeout(err error) bool {
	var pe *pgconn.PgError
	return errors.As(err, &pe) && pe.Code == "57014"
}
