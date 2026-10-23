package store

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// The receipt copy (spec 119 v1.1 sections 8.1 and 8.2, tasks.md T004): when
// a person's live access to a workspace ends, a read-only copy of their own
// hours goes to their realm FIRST, and only then does the change happen. Two
// steps, each its own transaction, the scopes never set together:
//
//  1. the workspace side, through the existing 107 store reads only
//     (GetTenant, HoursEntries, HoursPeriods) plus the approvers' display
//     names: no new SQL on any hours table, so 107's 1.7 grep test holds;
//  2. the realm side, appendRealmReceipts in inPerson: the rows at rev 0
//     (ON CONFLICT DO NOTHING, so a retry is idempotent) and the
//     receipt_due row (done unless a day is still open, 8.3).
//
// The caller makes the change (step 3) only when this returns nil. What a
// row carries is 8.2's list and nothing more: never the entry note, its
// updated_by, the target id (t:<topic> points into content) or a span.

// The receipt_due reasons (rdb 0168 CHECK).
const (
	RealmDueRemoved          = "removed"
	RealmDueAccessUntil      = "access_until"
	RealmDueWorkspaceDeleted = "workspace_deleted"
)

// realmStateOpen is the approval state (rdb 0168 CHECK) of a day with no
// period row whose freeze has not passed: 107 has no name for it.
const realmStateOpen = "open"

// RealmKindWork is 107 FR-27's default kind. Since rdb 0215 every entry
// carries its own kind (work, travel, wait, absence), copied as it is.
const RealmKindWork = HoursKindWork

// realmTextMax is rdb 0168's bound of workspace_name, label and approver_name.
const realmTextMax = 200

// ErrRealmCopy wraps a failed receipt copy: the change it guards must not
// happen (8.1: never a leaver without a receipt; 503 receipt_failed).
var ErrRealmCopy = errors.New("store: receipt copy failed")

// RealmReceiptDue is one personal.receipt_due row. LastOpenFrom is the first
// day not final at copy time ("" = none: the row is done at once).
type RealmReceiptDue struct {
	Reason       string
	LastOpenFrom string
	DueAt        time.Time
	DoneAt       *time.Time
}

// RealmReceiptCopier takes a person's receipt of one workspace (steps 1..2).
// Implemented by Memory and Postgres.
type RealmReceiptCopier interface {
	// CopyRealmReceipts copies person's hours in tenant to person's realm
	// with reason, and answers the rows written (0 on a retry). Every error
	// is ErrRealmCopy: the caller keeps the membership.
	CopyRealmReceipts(ctx context.Context, tenant, person, reason string, now time.Time) (int, error)
}

var (
	_ RealmReceiptCopier = (*Memory)(nil)
	_ RealmReceiptCopier = (*Postgres)(nil)
)

// realmCopySource is what the copy needs of a store: the 107 reads of step 1
// and the realm write of step 2.
type realmCopySource interface {
	GetTenant(ctx context.Context, tenantID string) (Tenant, error)
	HoursEntries(ctx context.Context, tenant, member, from, to string) ([]HoursEntry, error)
	HoursPeriods(ctx context.Context, tenant, member, from, to string) ([]HoursPeriod, error)
	DisplayName(ctx context.Context, humanID string) (string, error)
	appendRealmReceipts(ctx context.Context, person, workspaceID string, rows []RealmReceipt, due RealmReceiptDue) (int, error)
}

// The whole of a member's history: the copy takes every day the workspace
// still holds.
const (
	realmCopyFrom = "0001-01-01"
	realmCopyTo   = "9999-12-31"
)

// CopyRealmReceipts is RealmReceiptCopier.CopyRealmReceipts.
func (s *Memory) CopyRealmReceipts(ctx context.Context, tenant, person, reason string, now time.Time) (int, error) {
	return copyRealmReceipts(ctx, s, tenant, person, reason, now)
}

// CopyRealmReceipts is RealmReceiptCopier.CopyRealmReceipts.
func (s *Postgres) CopyRealmReceipts(ctx context.Context, tenant, person, reason string, now time.Time) (int, error) {
	return copyRealmReceipts(ctx, s, tenant, person, reason, now)
}

func copyRealmReceipts(ctx context.Context, st realmCopySource, tenant, person, reason string, now time.Time) (int, error) {
	fail := func(step string, err error) (int, error) {
		return 0, fmt.Errorf("%w: %s: %w", ErrRealmCopy, step, err)
	}
	if err := checkPerson(person); err != nil {
		return fail("person", err)
	}
	switch reason {
	case RealmDueRemoved, RealmDueAccessUntil, RealmDueWorkspaceDeleted:
	default:
		return fail("reason", fmt.Errorf("%w: reason %q", ErrRealmBad, reason))
	}
	// Step 1: the workspace side, 107's own reads.
	t, err := st.GetTenant(ctx, tenant)
	if err != nil {
		return fail("workspace", err)
	}
	entries, err := st.HoursEntries(ctx, tenant, person, realmCopyFrom, realmCopyTo)
	if err != nil {
		return fail("entries", err)
	}
	periods, err := st.HoursPeriods(ctx, tenant, person, realmCopyFrom, realmCopyTo)
	if err != nil {
		return fail("periods", err)
	}
	names, err := realmApproverNames(ctx, st, periods)
	if err != nil {
		return fail("approver", err)
	}
	in := make([]realmCopyEntry, 0, len(entries))
	for _, e := range entries {
		if e.State != HoursApproved {
			continue // a rejected entry counts 0 (107)
		}
		kind := e.Kind
		if kind == "" {
			kind = RealmKindWork
		}
		in = append(in, realmCopyEntry{Day: e.Day, Target: e.Target, Kind: kind, Minutes: e.Minutes})
	}
	name := t.DisplayName
	if name == "" {
		name = t.ID
	}
	rows, lastOpen := buildRealmReceipts(in, periods, HoursSettingsOf(t.Settings), tenant, name, names, now)
	// Step 2: the realm side, as the person.
	due := RealmReceiptDue{Reason: reason, LastOpenFrom: lastOpen, DueAt: now.UTC()}
	if lastOpen == "" {
		done := now.UTC()
		due.DoneAt = &done
	}
	n, err := st.appendRealmReceipts(ctx, person, tenant, rows, due)
	if err != nil {
		return fail("realm", err)
	}
	return n, nil
}

// realmApproverNames resolves each period decider to a display name at copy
// time (8.2; kept as long as the receipt, OQ-3 B). A decider since deleted
// is "".
func realmApproverNames(ctx context.Context, st realmCopySource, periods []HoursPeriod) (map[string]string, error) {
	names := map[string]string{}
	for _, p := range periods {
		if _, ok := names[p.DecidedBy]; ok || p.DecidedBy == "" {
			continue
		}
		n, err := st.DisplayName(ctx, p.DecidedBy)
		if err != nil && !errors.Is(err, ErrNotFound) {
			return nil, err
		}
		names[p.DecidedBy] = n
	}
	return names, nil
}

// realmCopyEntry is one approved entry as the copy reads it: the target only
// to derive the label, never kept.
type realmCopyEntry struct {
	Day, Target, Kind string
	Minutes           int
}

// RealmReceiptLabel is 8.2's label of an entry target: the type only for
// t:, ch:, dm:, cal: (a title is content), "workspace" for ws. A job: target
// (107 FR-18, not built yet) is "job" until a job store gives its name and
// site.
func RealmReceiptLabel(target string) string {
	if target == "ws" {
		return "workspace"
	}
	kind, _, _ := strings.Cut(target, ":")
	switch kind {
	case "t":
		return "topic"
	case "ch":
		return "channel"
	case "dm":
		return "direct message"
	case "cal":
		return "meeting"
	case "job":
		return "job"
	}
	return "other"
}

// realmReceiptKey is the key minutes are summed under (8.2).
type realmReceiptKey struct{ day, label, kind string }

// buildRealmReceipts is 8.2's rows for one workspace, by (day, label, kind),
// minutes summed per key, and the first day whose period is not final yet
// (open or returned; "" when every day is final). A frozen or approved
// period is final: 8.3's refresh runs when the period freezes or is
// approved.
func buildRealmReceipts(in []realmCopyEntry, periods []HoursPeriod, hs HoursSettings, ws, wsName string,
	names map[string]string, now time.Time) ([]RealmReceipt, string) {
	sum := map[realmReceiptKey]int{}
	for _, e := range in {
		sum[realmReceiptKey{e.Day, RealmReceiptLabel(e.Target), e.Kind}] += e.Minutes
	}
	keys := make([]realmReceiptKey, 0, len(sum))
	for k := range sum {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		a, b := keys[i], keys[j]
		if a.day != b.day {
			return a.day < b.day
		}
		if a.label != b.label {
			return a.label < b.label
		}
		return a.kind < b.kind
	})
	wsName = realmClip(wsName)
	lastOpen := ""
	out := make([]RealmReceipt, 0, len(keys))
	for _, k := range keys {
		day, err := ParseHoursDay(k.day)
		if err != nil {
			continue
		}
		r := realmReceiptRow(day, periods, hs, names, now)
		r.WorkspaceID, r.WorkspaceName, r.Day, r.Label, r.Kind = ws, wsName, k.day, k.label, k.kind
		r.Minutes = min(sum[k], HoursDayCap)
		if (r.ApprovalState == realmStateOpen || r.ApprovalState == HoursReturned) && lastOpen == "" {
			lastOpen = k.day // keys are sorted by day
		}
		out = append(out, r)
	}
	return out, lastOpen
}

// realmReceiptRow is the period half of a receipt row for day: its bounds,
// its approval state and its decider.
func realmReceiptRow(day time.Time, periods []HoursPeriod, hs HoursSettings, names map[string]string, now time.Time) RealmReceipt {
	start, end, row := HoursPeriodFor(day, periods, hs)
	r := RealmReceipt{PeriodStart: start.Format(hoursDay), PeriodEnd: end.Format(hoursDay),
		ApprovalState: realmStateOpen, CopiedAt: now.UTC()}
	switch {
	case row != nil:
		r.ApprovalState = row.State
		if row.DecidedBy != "" {
			r.ApproverName = realmClip(names[row.DecidedBy])
			at := row.DecidedAt.UTC()
			r.DecidedAt = &at
		}
	case HoursDayFrozen(day, periods, hs, now):
		r.ApprovalState = HoursFrozen
	}
	return r
}

// realmClip cuts s to rdb 0168's 200 characters, on a rune boundary.
func realmClip(s string) string {
	if utf8.RuneCountInString(s) <= realmTextMax {
		return s
	}
	return string([]rune(s)[:realmTextMax])
}

// RealmPerson reports whether id can hold a realm (a HUM-* person id); a
// member id that cannot takes no receipt.
func RealmPerson(id string) bool { return checkPerson(id) == nil }
