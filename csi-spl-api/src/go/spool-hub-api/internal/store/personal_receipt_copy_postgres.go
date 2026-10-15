package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// The realm side of the receipt copy (personal_receipt_copy.go, step 2): one
// inPerson transaction, the rows and the receipt_due row together. The
// runtime login has INSERT only on hours_receipts (rdb 0168, 7.5), so a row
// once written never changes: ON CONFLICT DO NOTHING keeps the first copy of
// a day, and a retry writes 0 rows.

const realmReceiptsInsert = `INSERT INTO personal.hours_receipts (person_id, workspace_id, workspace_name, day,
		minutes, label, kind, period_start, period_end, approval_state, approver_name, decided_at, rev, copied_at)
	SELECT $1, $2, $3, u.d, u.m, u.l, u.k, u.ps, u.pe, u.st, NULLIF(u.an, ''), u.da, 0, $13
	FROM unnest($4::date[], $5::int[], $6::text[], $7::text[], $8::date[], $9::date[], $10::text[], $11::text[],
		$12::timestamptz[]) AS u(d, m, l, k, ps, pe, st, an, da)
	ON CONFLICT (person_id, workspace_id, day, label, kind, rev) DO NOTHING`

// realmDueUpsert opens or refreshes the (person, workspace) row. A row still
// open keeps its earliest open day and stays open: a second leave (after a
// rejoin) never closes a refresh the first one still waits for.
const realmDueUpsert = `INSERT INTO personal.receipt_due (person_id, workspace_id, reason, due_at, last_open_from, done_at)
	VALUES ($1, $2, $3, $4, NULLIF($5, '')::date, $6)
	ON CONFLICT (person_id, workspace_id) DO UPDATE SET
		reason = EXCLUDED.reason, due_at = EXCLUDED.due_at,
		last_open_from = CASE WHEN receipt_due.done_at IS NULL
			THEN LEAST(receipt_due.last_open_from, EXCLUDED.last_open_from) ELSE EXCLUDED.last_open_from END,
		done_at = CASE WHEN receipt_due.done_at IS NULL THEN NULL ELSE EXCLUDED.done_at END`

func (s *Postgres) appendRealmReceipts(ctx context.Context, person, workspaceID string, rows []RealmReceipt, due RealmReceiptDue) (int, error) {
	if err := checkPerson(person); err != nil {
		return 0, err
	}
	if err := checkRealmWorkspace(workspaceID); err != nil {
		return 0, err
	}
	name := ""
	n := len(rows)
	days, labels, kinds := make([]string, n), make([]string, n), make([]string, n)
	starts, ends, states, approvers := make([]string, n), make([]string, n), make([]string, n), make([]string, n)
	mins, decided := make([]int32, n), make([]*time.Time, n)
	for i, r := range rows {
		name = r.WorkspaceName
		days[i], mins[i], labels[i], kinds[i] = r.Day, int32(r.Minutes), r.Label, r.Kind
		starts[i], ends[i], states[i], approvers[i], decided[i] = r.PeriodStart, r.PeriodEnd, r.ApprovalState, r.ApproverName, r.DecidedAt
	}
	var written int
	err := s.inPerson(ctx, person, func(tx pgx.Tx) error {
		if n > 0 {
			tag, err := tx.Exec(ctx, realmReceiptsInsert, person, workspaceID, name, days, mins, labels, kinds,
				starts, ends, states, approvers, decided, due.DueAt.UTC())
			if err != nil {
				return err
			}
			written = int(tag.RowsAffected())
		}
		_, err := tx.Exec(ctx, realmDueUpsert, person, workspaceID, due.Reason, due.DueAt.UTC(), due.LastOpenFrom, due.DoneAt)
		return err
	})
	return written, realmPGErr(err)
}
