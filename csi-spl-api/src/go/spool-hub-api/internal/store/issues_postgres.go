package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Postgres side of rdb 0047. Every statement runs in the tenant scope.

const issueCols = `number, title, description, status, priority, level, assignee, labels, deadline,
	COALESCE(parent_number, 0), task_id::text, created_by, created_at, updated_by, updated_at, completed_at, canceled_at, kind`

// issueSheetCols is issueCols without description: what the issue sheet
// paints (perf round 5 P5-06). The open issue is GetIssue's read.
const issueSheetCols = `number, title, status, priority, level, assignee, labels, deadline,
	COALESCE(parent_number, 0), task_id::text, created_by, created_at, updated_by, updated_at, completed_at, canceled_at, kind`

func scanIssue(row pgx.Row, tenant, prefix string) (Issue, error) {
	i := Issue{TenantID: tenant, Prefix: prefix}
	err := row.Scan(&i.Number, &i.Title, &i.Description, &i.Status, &i.Priority, &i.Level, &i.Assignee, &i.Labels,
		&i.Deadline, &i.Parent, &i.TaskID, &i.CreatedBy, &i.CreatedAt, &i.UpdatedBy, &i.UpdatedAt, &i.CompletedAt, &i.CanceledAt, &i.Kind)
	return issueRead(i, err)
}

// scanIssueSheet reads an issueSheetCols row: Description stays "".
func scanIssueSheet(row pgx.Row, tenant, prefix string) (Issue, error) {
	i := Issue{TenantID: tenant, Prefix: prefix}
	err := row.Scan(&i.Number, &i.Title, &i.Status, &i.Priority, &i.Level, &i.Assignee, &i.Labels,
		&i.Deadline, &i.Parent, &i.TaskID, &i.CreatedBy, &i.CreatedAt, &i.UpdatedBy, &i.UpdatedAt, &i.CompletedAt, &i.CanceledAt, &i.Kind)
	return issueRead(i, err)
}

// issueRead is the tail both scans share.
func issueRead(i Issue, err error) (Issue, error) {
	if i.Labels == nil {
		i.Labels = []string{}
	}
	i.Status = NormalizeIssueStatus(i.Status) // a first-set status from the roll window
	if i.Priority == 0 {                      // written by a hub older than rdb 0055
		i.Priority = IssuePriorityDefault
	}
	return i, err
}

// txPrefix reads the tenant's prefix inside tx.
func txPrefix(ctx context.Context, tx pgx.Tx, tenant string) (string, error) {
	var p string
	err := tx.QueryRow(ctx, `SELECT prefix FROM issue_counters WHERE tenant_id = $1`, tenant).Scan(&p)
	if errors.Is(err, pgx.ErrNoRows) {
		return IssuePrefixDefault, nil
	}
	return p, err
}

// The reads txIssueRefs makes. The parent row is locked FOR SHARE, so it
// cannot change kind (UpdateIssue locks FOR UPDATE) while an issue is being
// put under it.
const (
	issueLabelCount = `SELECT count(*) FROM issue_labels WHERE tenant_id = $1 AND label_id = ANY($2)`
	issueParentRef  = `SELECT p.kind, COALESCE(p.parent_number, 0), COALESCE(g.kind, '')
		FROM issues p LEFT JOIN issues g ON g.tenant_id = p.tenant_id AND g.number = p.parent_number
		WHERE p.tenant_id = $1 AND p.number = $2 AND p.deleted_at IS NULL AND p.archived_at IS NULL FOR SHARE OF p`
)

// labelCount reads issueLabelCount's row: ErrUnknownLabel when a label of i
// does not exist.
func labelCount(row pgx.Row, i *Issue) error {
	var n int
	if err := row.Scan(&n); err != nil {
		return err
	}
	if n != len(i.Labels) {
		return ErrUnknownLabel
	}
	return nil
}

// parentRef reads issueParentRef's row into r; no row leaves parentOK false.
func parentRef(row pgx.Row, r *treeRefs) error {
	var grand string
	err := row.Scan(&r.parent.Kind, &r.parent.Parent, &grand)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
	case err != nil:
		return err
	default:
		r.parentOK = true
		r.parentLevel2 = !r.parent.IsEpic() && (r.parent.Parent == 0 || (Issue{Kind: grand}).IsEpic())
	}
	return nil
}

// txIssueRefs checks labels and, with rule, the tree rule (SPL-18) inside tx,
// and derives i.Level (want: the caller's level, 0 none).
func txIssueRefs(ctx context.Context, tx pgx.Tx, i *Issue, rule, wasEpic bool, want int) error {
	if len(i.Labels) > 0 {
		if err := labelCount(tx.QueryRow(ctx, issueLabelCount, i.TenantID, i.Labels), i); err != nil {
			return err
		}
	}
	r := treeRefs{wasEpic: wasEpic}
	if i.Parent != 0 {
		if err := parentRef(tx.QueryRow(ctx, issueParentRef, i.TenantID, i.Parent), &r); err != nil {
			return err
		}
	}
	if !rule {
		return setLevel(i, r, want)
	}
	if i.Number != 0 {
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM issues WHERE tenant_id = $1 AND parent_number = $2 AND deleted_at IS NULL AND archived_at IS NULL)`,
			i.TenantID, i.Number).Scan(&r.hasChildren); err != nil {
			return err
		}
	}
	if err := treeRule(*i, r); err != nil {
		return err
	}
	return setLevel(i, r, want)
}

func nullParent(p int) any {
	if p == 0 {
		return nil
	}
	return p
}

func (s *Postgres) CreateIssue(ctx context.Context, in Issue, now time.Time) (Issue, error) {
	in.UpdatedBy = in.CreatedBy
	if in.Status == "" {
		in.Status = IssueBacklog
	}
	if err := checkIssue(&in); err != nil {
		return Issue{}, err
	}
	now = now.UTC().Truncate(time.Microsecond)
	stampStatus(&in, now)
	if err := checkTenant(in.TenantID); err != nil {
		return Issue{}, err
	}
	c, err := s.pool.Acquire(ctx)
	if err != nil {
		return Issue{}, err
	}
	defer c.Release() // a conn still inside a transaction is destroyed, never reused
	out, err := createIssueOn(ctx, c.Conn(), in, now)
	if err != nil && c.Conn().PgConn().TxStatus() != 'I' {
		c.Exec(ctx, `ROLLBACK`) //nolint:errcheck
	}
	return out, pgIssueErr(err)
}

// createIssueOn is CreateIssue's transaction in TWO round trips (it took six
// to eight under inTenant): one batch opens it, sets the tenant scope (local
// to it, as inTenant's) and makes every read the checks need; the second
// takes the number, inserts the row and commits. Each batch runs in queue
// order and is read in that order, so the error returned is the one the
// statement-at-a-time form returned: unknown tenant, then label, then the
// tree rule. A failure leaves the transaction open for the caller's ROLLBACK.
func createIssueOn(ctx context.Context, conn *pgx.Conn, in Issue, now time.Time) (Issue, error) {
	b := &pgx.Batch{}
	b.Queue(`BEGIN`)
	b.Queue(pgScopeTenant, in.TenantID)
	b.Queue(`SELECT EXISTS (SELECT 1 FROM tenants WHERE tenant_id = $1)`, in.TenantID)
	if len(in.Labels) > 0 {
		b.Queue(issueLabelCount, in.TenantID, in.Labels)
	}
	if in.Parent != 0 {
		b.Queue(issueParentRef, in.TenantID, in.Parent)
	}
	r := treeRefs{}
	err := func() error {
		br := conn.SendBatch(ctx, b)
		defer br.Close()
		for range 2 { // BEGIN, scope
			if _, err := br.Exec(); err != nil {
				return err
			}
		}
		var ok bool
		if err := br.QueryRow().Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return ErrNotFound
		}
		if len(in.Labels) > 0 {
			if err := labelCount(br.QueryRow(), &in); err != nil {
				return err
			}
		}
		if in.Parent != 0 {
			if err := parentRef(br.QueryRow(), &r); err != nil {
				return err
			}
		}
		return br.Close()
	}()
	if err != nil {
		return Issue{}, err
	}
	if err := treeRule(in, r); err != nil {
		return Issue{}, err
	}
	if err := setLevel(&in, r, in.Level); err != nil {
		return Issue{}, err
	}
	return insertIssueOn(ctx, conn, in, now)
}

// insertIssueOn is createIssueOn's second round trip: it takes the number,
// inserts the row, writes the assignee's Flow watch (spec 130 section 3) and
// commits.
func insertIssueOn(ctx context.Context, conn *pgx.Conn, in Issue, now time.Time) (Issue, error) {
	// The counter row is the lock: two creates in one tenant serialize on it
	// and never share a number. The INSERT reads the number the upsert just
	// wrote, in the same transaction.
	b := &pgx.Batch{}
	b.Queue(`INSERT INTO issue_counters (tenant_id, last_number) VALUES ($1, 1)
		ON CONFLICT (tenant_id) DO UPDATE SET last_number = issue_counters.last_number + 1
		RETURNING prefix`, in.TenantID)
	b.Queue(`INSERT INTO issues (tenant_id, number, title, description, status, priority, level,
			assignee, labels, deadline, parent_number, task_id, created_by, created_at, updated_by, updated_at,
			completed_at, canceled_at, kind)
		VALUES ($1, (SELECT last_number FROM issue_counters WHERE tenant_id = $1), $2, $3, $4, $5, $6, $7, $8, $9, $10,
			$11, $12, $13, $12, $13, $14, $15, $16)
		RETURNING `+issueCols,
		in.TenantID, in.Title, in.Description, in.Status, in.Priority, in.Level, in.Assignee, in.Labels,
		in.Deadline, nullParent(in.Parent), in.TaskID, in.CreatedBy, now, in.CompletedAt, in.CanceledAt, in.Kind)
	b.Queue(flowWatchAssigneeSQL, in.TenantID, in.TaskID, in.Assignee, now)
	b.Queue(`COMMIT`)
	br := conn.SendBatch(ctx, b)
	defer br.Close()
	var prefix string
	if err := br.QueryRow().Scan(&prefix); err != nil {
		return Issue{}, err
	}
	out, err := scanIssue(br.QueryRow(), in.TenantID, prefix)
	if err != nil {
		return Issue{}, err
	}
	for range 2 { // the assignee's watch, COMMIT
		if _, err := br.Exec(); err != nil {
			return Issue{}, err
		}
	}
	return out, br.Close()
}

// flowWatchAssigneeUpsert writes the Flow watch of an issue's assignee on its
// topic (spec 130 section 3): setting an assignee makes them part of the
// discussion. Human seats only (an agent's inbox already carries its
// lines); never a second row. Its arguments are SQL expressions.
func flowWatchAssigneeUpsert(tenant, task, assignee, at string) string {
	return `INSERT INTO flow_watches (tenant_id, task_id, member_id, since)
		SELECT ` + tenant + `, ` + task + `, ` + assignee + `, ` + at + ` WHERE ` + assignee + ` ~ '^(HUM|GST)-[0-9]+$'
		ON CONFLICT DO NOTHING`
}

// flowWatchAssigneeSQL is that write alone, in CreateIssue's batch (no extra
// round trip): $1 tenant, $2 task, $3 assignee, $4 now.
var flowWatchAssigneeSQL = flowWatchAssigneeUpsert("$1", "$2::uuid", "$3::text", "$4::timestamptz")

func (s *Postgres) UpdateIssue(ctx context.Context, tenant string, number int, p IssuePatch, by string, now time.Time) (Issue, error) {
	want, err := patchLevel(p)
	if err != nil {
		return Issue{}, err
	}
	now = now.UTC().Truncate(time.Microsecond)
	var out Issue
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		prefix, err := txPrefix(ctx, tx, tenant)
		if err != nil {
			return err
		}
		cur, err := scanIssue(tx.QueryRow(ctx, `SELECT `+issueCols+` FROM issues
			WHERE tenant_id = $1 AND number = $2 AND deleted_at IS NULL AND archived_at IS NULL FOR UPDATE`, tenant, number), tenant, prefix)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		wasEpic, was, wasStatus, wasParent := cur.IsEpic(), cur.Level, cur.Status, cur.Parent
		applyPatch(&cur, p, by, now)
		if err := checkIssue(&cur); err != nil {
			return err
		}
		if err := txIssueRefs(ctx, tx, &cur, epicTouched(p), wasEpic, want); err != nil {
			return err
		}
		if cur.Level != was { // an issue made an epic: its subtasks are issues now
			// updated_by / updated_at name who moved them in their history (rdb 0181)
			if _, err := tx.Exec(ctx, `UPDATE issues SET level = $3, updated_by = $4, updated_at = $5
				WHERE tenant_id = $1 AND parent_number = $2`,
				tenant, number, cur.Level+1, by, now); err != nil {
				return err
			}
		}
		out, err = scanIssue(tx.QueryRow(ctx, `WITH w AS (`+flowWatchAssigneeUpsert("$1", "$17::uuid", "$8", "$13")+`)
			UPDATE issues SET title = $3, description = $4, status = $5,
				priority = $6, level = $7, assignee = $8, labels = $9, deadline = $10, parent_number = $11,
				updated_by = $12, updated_at = $13, completed_at = $14, canceled_at = $15, kind = $16
			WHERE tenant_id = $1 AND number = $2
			RETURNING `+issueCols,
			tenant, number, cur.Title, cur.Description, cur.Status, cur.Priority, cur.Level, cur.Assignee, cur.Labels,
			cur.Deadline, nullParent(cur.Parent), cur.UpdatedBy, cur.UpdatedAt, cur.CompletedAt, cur.CanceledAt, cur.Kind, cur.TaskID), tenant, prefix)
		switch {
		case err != nil:
			return err
		case ClosesEpic(wasStatus, out):
			return txCloseEpic(ctx, tx, &out, by, now) // SPL-1643
		case ClosesChild(wasStatus, wasParent, out):
			out.AutoClosedEpic, err = txAutoCloseEpic(ctx, tx, tenant, prefix, out.Parent, by, now) // SPL-1729
		}
		return err
	})
	return out, pgIssueErr(err)
}

func (s *Postgres) GetIssue(ctx context.Context, tenant string, number int) (Issue, error) {
	var out Issue
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		prefix, err := txPrefix(ctx, tx, tenant)
		if err != nil {
			return err
		}
		out, err = scanIssue(tx.QueryRow(ctx, `SELECT `+issueCols+` FROM issues WHERE tenant_id = $1 AND number = $2 AND deleted_at IS NULL AND archived_at IS NULL`,
			tenant, number), tenant, prefix)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	})
	return out, err
}

func (s *Postgres) ListIssues(ctx context.Context, tenant string) ([]Issue, error) {
	return s.listIssueRows(ctx, tenant, issueCols, scanIssue)
}

// ListIssueSheet is ListIssues without description, for the issue sheet
// (P5-06: up to 0.9 MB of description detoasted per list read on prd).
// Search, hours export and the calendar keep ListIssues.
func (s *Postgres) ListIssueSheet(ctx context.Context, tenant string) ([]Issue, error) {
	return s.listIssueRows(ctx, tenant, issueSheetCols, scanIssueSheet)
}

func (s *Postgres) listIssueRows(ctx context.Context, tenant, cols string, scan func(pgx.Row, string, string) (Issue, error)) ([]Issue, error) {
	out := []Issue{}
	prefix := IssuePrefixDefault
	err := s.queryTenantBatch(ctx, tenant,
		tenantRead{sql: `SELECT prefix FROM issue_counters WHERE tenant_id = $1`, args: []any{tenant},
			each: func(r pgx.Rows) error { return r.Scan(&prefix) }},
		tenantRead{sql: `SELECT ` + cols + ` FROM issues WHERE tenant_id = $1 AND deleted_at IS NULL AND archived_at IS NULL ORDER BY number DESC`, args: []any{tenant},
			each: func(r pgx.Rows) error {
				i, err := scan(r, tenant, "")
				out = append(out, i)
				return err
			}})
	for k := range out {
		out[k].Prefix = prefix
	}
	return out, err
}

// DeleteIssue: the soft delete of rdb 0071. The row is locked FOR UPDATE, so
// a concurrent create cannot put a child under it between the check and the
// stamp (txIssueRefs locks the parent FOR SHARE).
func (s *Postgres) DeleteIssue(ctx context.Context, tenant string, number int, by string, now time.Time) (Issue, error) {
	now = now.UTC().Truncate(time.Microsecond)
	var out Issue
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		prefix, err := txPrefix(ctx, tx, tenant)
		if err != nil {
			return err
		}
		out, err = scanIssue(tx.QueryRow(ctx, `SELECT `+issueCols+` FROM issues
			WHERE tenant_id = $1 AND number = $2 AND deleted_at IS NULL AND archived_at IS NULL FOR UPDATE`, tenant, number), tenant, prefix)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		var kids bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM issues WHERE tenant_id = $1 AND parent_number = $2 AND deleted_at IS NULL AND archived_at IS NULL)`,
			tenant, number).Scan(&kids); err != nil {
			return err
		}
		if kids {
			return ErrIssueHasChildren
		}
		_, err = tx.Exec(ctx, `UPDATE issues SET deleted_at = $3, deleted_by = $4 WHERE tenant_id = $1 AND number = $2`,
			tenant, number, now, by)
		return err
	})
	return out, pgIssueErr(err)
}

// cascadeOp is one archive / delete / unarchive of a subtree (SPL-1039: the
// values of a cascadeStamp call belong together, so they ride one struct).
//
//	live    - the WHERE predicate of a row eligible to be touched ("deleted_at
//	          IS NULL"), used for the target, its children check and the walk
//	set     - the SET clause ($3 = now, $4 = by)
//	cascade - true takes the whole subtree; false refuses a live parent
type cascadeOp struct {
	tenant  string
	number  int
	by      string
	now     time.Time
	live    string
	set     string
	cascade bool
	// epicTree: a level-1 target takes its subtree whatever cascade says
	// (SPL-1643: unarchiving an epic brings its issues back).
	epicTree bool
}

// cascadeStamp walks the subtree rooted at op.number (parent_number, at most
// three levels but the CTE is general) and stamps op.set on the target and every
// descendant that still satisfies op.live, all in one statement so the whole
// epic or feature moves together (SPL-1226). `out` is filled with the target
// row as it was; the returned numbers are the descendants also touched (target
// excluded), sorted. ErrNotFound when the target is not eligible.
func (s *Postgres) cascadeStamp(ctx context.Context, op cascadeOp, out *Issue) ([]int, error) {
	var kids []int
	err := s.inTenant(ctx, op.tenant, func(tx pgx.Tx) error {
		prefix, err := txPrefix(ctx, tx, op.tenant)
		if err != nil {
			return err
		}
		row, err := scanIssue(tx.QueryRow(ctx, `SELECT `+issueCols+` FROM issues
			WHERE tenant_id = $1 AND number = $2 AND `+op.live+` FOR UPDATE`, op.tenant, op.number), op.tenant, prefix)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		*out = row
		if !op.cascade && !(op.epicTree && row.IsEpic()) {
			var has bool
			if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM issues
				WHERE tenant_id = $1 AND parent_number = $2 AND `+op.live+`)`, op.tenant, op.number).Scan(&has); err != nil {
				return err
			}
			if has {
				return ErrIssueHasChildren
			}
			_, err := tx.Exec(ctx, `UPDATE issues SET `+op.set+` WHERE tenant_id = $1 AND number = $2`, op.tenant, op.number, op.now, op.by)
			return err
		}
		kids, err = txStampTree(ctx, tx, op)
		return err
	})
	if err != nil {
		return nil, pgIssueErr(err)
	}
	return kids, nil
}

// txStampTree is cascadeStamp's walk inside tx: it stamps op.set on op.number
// and every descendant that satisfies op.live, in one statement, and answers
// the descendants touched (target excluded), sorted. UpdateIssue runs it when
// it closes an epic (SPL-1643).
func txStampTree(ctx context.Context, tx pgx.Tx, op cascadeOp) ([]int, error) {
	rows, err := tx.Query(ctx, `WITH RECURSIVE tree AS (
			SELECT number FROM issues WHERE tenant_id = $1 AND number = $2 AND `+op.live+`
			UNION ALL
			SELECT c.number FROM issues c JOIN tree t ON c.parent_number = t.number
				WHERE c.tenant_id = $1 AND `+op.live+`)
		UPDATE issues SET `+op.set+` WHERE tenant_id = $1 AND number IN (SELECT number FROM tree)
		RETURNING number`, op.tenant, op.number, op.now, op.by)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var kids []int
	for rows.Next() {
		var n int
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		if n != op.number {
			kids = append(kids, n)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sortInts(kids)
	return kids, nil
}

func sortInts(a []int) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && a[j-1] > a[j]; j-- {
			a[j-1], a[j] = a[j], a[j-1]
		}
	}
}

func (s *Postgres) DeleteIssueCascade(ctx context.Context, tenant string, number int, by string, now time.Time) (Issue, []int, error) {
	var out Issue
	kids, err := s.cascadeStamp(ctx, cascadeOp{
		tenant: tenant, number: number, by: by, now: now.UTC().Truncate(time.Microsecond),
		live: "deleted_at IS NULL AND archived_at IS NULL", set: "deleted_at = $3, deleted_by = $4", cascade: true,
	}, &out)
	return out, kids, err
}

// txCloseEpic closes and archives an epic's issues (ClosesEpic, SPL-1643)
// inside UpdateIssue's transaction, under a savepoint: a failure rolls back
// the cascade alone, so the epic's own status change stands, and is
// answered in out.CascadeErr / CascadeOpen, not as an error.
func txCloseEpic(ctx context.Context, tx pgx.Tx, out *Issue, by string, now time.Time) error {
	sp, err := tx.Begin(ctx)
	if err != nil {
		return err
	}
	err = runEpicCloseFault(out.TenantID, out.Number)
	if err == nil {
		err = txCloseTree(ctx, sp, out, by, now)
	}
	if err == nil {
		out.ArchivedWith, err = txStampTree(ctx, sp, archiveOp(out.TenantID, out.Number, by, now, true))
	}
	if err == nil {
		out.ClosedArchived = true
		return sp.Commit(ctx)
	}
	if rbErr := sp.Rollback(ctx); rbErr != nil {
		return rbErr
	}
	out.ClosedWith, out.ArchivedWith, out.CascadeErr = nil, nil, err.Error()
	open, oerr := txOpenTree(ctx, tx, out.TenantID, out.Number)
	out.CascadeOpen = open
	return oerr
}

// txAutoCloseEpic closes the open epic above parent when none of its live
// issues is open any more (ClosesChild, EpicAutoStatus; SPL-1729), through
// txCloseEpic's cascade, and answers it, or nil. The epic row is locked
// before its issues are counted: two of its last issues closing at once
// serialize on it, and the second one counts the first one's close.
func txAutoCloseEpic(ctx context.Context, tx pgx.Tx, tenant, prefix string, parent int, by string, now time.Time) (*Issue, error) {
	var epic int
	err := tx.QueryRow(ctx, `WITH RECURSIVE up AS (
			SELECT number, parent_number, kind, 0 AS hop FROM issues
				WHERE tenant_id = $1 AND number = $2 AND deleted_at IS NULL AND archived_at IS NULL
			UNION ALL
			SELECT p.number, p.parent_number, p.kind, up.hop + 1 FROM issues p JOIN up ON p.number = up.parent_number
				WHERE p.tenant_id = $1 AND p.deleted_at IS NULL AND p.archived_at IS NULL AND up.hop < 8)
		SELECT number FROM up WHERE kind IN ($3, $4) ORDER BY hop LIMIT 1`,
		tenant, parent, IssueKindEpic, IssueKindFeature).Scan(&epic)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	cur, err := scanIssue(tx.QueryRow(ctx, `SELECT `+issueCols+` FROM issues
		WHERE tenant_id = $1 AND number = $2 AND deleted_at IS NULL AND archived_at IS NULL FOR UPDATE`, tenant, epic), tenant, prefix)
	if err != nil || IssueClosed(cur.Status) {
		return nil, err
	}
	var total, open, done int
	if err := tx.QueryRow(ctx, epicTreeCTE+`
		SELECT count(*), count(*) FILTER (WHERE status NOT IN ('done', 'diss')), count(*) FILTER (WHERE status = 'done')
		FROM issues WHERE tenant_id = $1 AND number IN (SELECT number FROM tree)`, tenant, epic).Scan(&total, &open, &done); err != nil {
		return nil, err
	}
	st, ok := EpicAutoStatus(total, open, done)
	if !ok {
		return nil, nil
	}
	cur.Status = st
	stampStatus(&cur, now)
	out, err := scanIssue(tx.QueryRow(ctx, `UPDATE issues SET status = $3, updated_by = $4, updated_at = $5,
			completed_at = $6, canceled_at = $7
		WHERE tenant_id = $1 AND number = $2
		RETURNING `+issueCols, tenant, epic, cur.Status, by, now, cur.CompletedAt, cur.CanceledAt), tenant, prefix)
	if err != nil {
		return nil, err
	}
	return &out, txCloseEpic(ctx, tx, &out, by, now)
}

// epicTreeCTE is the live subtree under $2 (target excluded).
const epicTreeCTE = `WITH RECURSIVE tree AS (
		SELECT number FROM issues WHERE tenant_id = $1 AND parent_number = $2 AND deleted_at IS NULL AND archived_at IS NULL
		UNION ALL
		SELECT c.number FROM issues c JOIN tree t ON c.parent_number = t.number
			WHERE c.tenant_id = $1 AND c.deleted_at IS NULL AND c.archived_at IS NULL)`

// txCloseTree gives every open live descendant the epic's status, stamped as
// applyPatch stamps it; out.ClosedWith answers which.
func txCloseTree(ctx context.Context, tx pgx.Tx, out *Issue, by string, now time.Time) error {
	rows, err := tx.Query(ctx, epicTreeCTE+`
		UPDATE issues SET status = $3, updated_by = $4, updated_at = $5,
			completed_at = CASE WHEN $3 = 'done' THEN $5::timestamptz END,
			canceled_at = CASE WHEN $3 = 'diss' THEN $5::timestamptz END
		WHERE tenant_id = $1 AND number IN (SELECT number FROM tree) AND status NOT IN ('done', 'diss')
		RETURNING number`, out.TenantID, out.Number, out.Status, by, now)
	if err != nil {
		return err
	}
	out.ClosedWith, err = scanNumbers(rows)
	return err
}

// txOpenTree is the open live descendants of number, sorted.
func txOpenTree(ctx context.Context, tx pgx.Tx, tenant string, number int) ([]int, error) {
	rows, err := tx.Query(ctx, epicTreeCTE+`
		SELECT number FROM issues WHERE tenant_id = $1 AND number IN (SELECT number FROM tree) AND status NOT IN ('done', 'diss')`,
		tenant, number)
	if err != nil {
		return nil, err
	}
	return scanNumbers(rows)
}

// scanNumbers reads one int column, closes rows and sorts.
func scanNumbers(rows pgx.Rows) ([]int, error) {
	defer rows.Close()
	var out []int
	for rows.Next() {
		var n int
		if err := rows.Scan(&n); err != nil {
			return nil, err
		}
		out = append(out, n)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sortInts(out)
	return out, nil
}

// archiveOp is the soft archive of rdb 0084 as a cascadeOp: ArchiveIssue's,
// and UpdateIssue's when it closes an epic.
func archiveOp(tenant string, number int, by string, now time.Time, cascade bool) cascadeOp {
	return cascadeOp{
		tenant: tenant, number: number, by: by, now: now.UTC().Truncate(time.Microsecond),
		live: "deleted_at IS NULL AND archived_at IS NULL", set: "archived_at = $3, archived_by = $4", cascade: cascade,
	}
}

func (s *Postgres) ArchiveIssue(ctx context.Context, tenant string, number int, by string, now time.Time, cascade bool) (Issue, []int, error) {
	var out Issue
	kids, err := s.cascadeStamp(ctx, archiveOp(tenant, number, by, now, cascade), &out)
	return out, kids, err
}

func (s *Postgres) UnarchiveIssue(ctx context.Context, tenant string, number int, by string, now time.Time, cascade bool) (Issue, []int, error) {
	var out Issue
	// Unarchive clears both stamps and refreshes the audit columns, which also
	// keeps cascadeStamp's one shape (the $3 = now, $4 = by placeholders).
	kids, err := s.cascadeStamp(ctx, cascadeOp{
		tenant: tenant, number: number, by: by, now: now.UTC().Truncate(time.Microsecond),
		live: "deleted_at IS NULL AND archived_at IS NOT NULL", set: "archived_at = NULL, archived_by = NULL, updated_at = $3, updated_by = $4", cascade: cascade,
		epicTree: true,
	}, &out)
	return out, kids, err
}

func (s *Postgres) IssuePrefix(ctx context.Context, tenant string) (string, error) {
	p := IssuePrefixDefault
	err := s.queryRowTenant(ctx, tenant, `SELECT prefix FROM issue_counters WHERE tenant_id = $1`, []any{tenant}, &p)
	if errors.Is(err, pgx.ErrNoRows) {
		return IssuePrefixDefault, nil
	}
	return p, err
}

func (s *Postgres) SetIssuePrefix(ctx context.Context, tenant, prefix string) (string, error) {
	p, err := CheckIssuePrefix(prefix)
	if err != nil {
		return "", err
	}
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var ok bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM tenants WHERE tenant_id = $1)`, tenant).Scan(&ok); err != nil {
			return err
		}
		if !ok {
			return ErrNotFound
		}
		_, err := tx.Exec(ctx, `INSERT INTO issue_counters (tenant_id, prefix) VALUES ($1, $2)
			ON CONFLICT (tenant_id) DO UPDATE SET prefix = EXCLUDED.prefix`, tenant, p)
		return err
	})
	return p, err
}

func (s *Postgres) ListIssueLabels(ctx context.Context, tenant string) ([]IssueLabel, error) {
	out := []IssueLabel{}
	err := s.queryTenant(ctx, tenant, `SELECT label_id, name, color, created_by, created_at FROM issue_labels
		WHERE tenant_id = $1`, []any{tenant}, func(r pgx.Rows) error {
		l := IssueLabel{TenantID: tenant}
		out = append(out, l)
		k := &out[len(out)-1]
		return r.Scan(&k.LabelID, &k.Name, &k.Color, &k.CreatedBy, &k.CreatedAt)
	})
	sortLabels(out)
	return out, err
}

func (s *Postgres) CreateIssueLabel(ctx context.Context, l IssueLabel, now time.Time) (IssueLabel, error) {
	if err := checkLabel(&l); err != nil {
		return IssueLabel{}, err
	}
	l.CreatedAt = now.UTC().Truncate(time.Microsecond)
	tag, err := s.execTenant(ctx, l.TenantID, `INSERT INTO issue_labels (tenant_id, label_id, name, color, created_by, created_at)
		VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT DO NOTHING`, l.TenantID, l.LabelID, l.Name, l.Color, l.CreatedBy, l.CreatedAt)
	if err != nil {
		return IssueLabel{}, pgIssueErr(err)
	}
	if tag.RowsAffected() == 0 {
		return IssueLabel{}, ErrConflict
	}
	return l, nil
}

// pgIssueErr maps the constraint errors a race can still reach to the
// store's own: an unknown tenant (FK) and a check the Go side missed.
func pgIssueErr(err error) error {
	var pe *pgconn.PgError
	if errors.As(err, &pe) {
		switch pe.Code {
		case "23503":
			if pe.ConstraintName == "issues_tenant_id_parent_number_fkey" {
				return ErrUnknownParent
			}
			return ErrNotFound
		case "23514":
			return fmt.Errorf("%w: %s", ErrInvalidIssue, pe.ConstraintName)
		case "23505":
			return ErrConflict
		}
	}
	return err
}
