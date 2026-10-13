package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// The personal realm store (spec 119 v1.1 section 7.2, tasks.md T002) over
// rdb 0168's schema `personal`: a person-level layer ABOVE the workspaces.
// Every call takes the person it is for, and that person comes only from the
// authenticated human session (never from a path, query, header or body);
// the store has no "read person X" call. The Postgres side runs every
// statement in inPerson (rls.go): the person scope alone, never a tenant
// scope, never the operator scope. The store owns:
//   - the profile: time zone (118 C4), locale and communication
//     preferences; one row per person, put whole;
//   - the hours limits (118 C3): a change appends a row from its valid_from
//     day, so a past week is judged by the limit it had;
//   - the receipts (8.2, 118 C5): read-only here, the newest rev per
//     (workspace, day, label, kind); their one removal is the person's own
//     erasure, personal.delete_my_receipts (8.3, OQ-4 A). Writing receipts
//     is the receipt copy's (T004), not this file's.

// ErrRealmBad: a realm value outside rdb 0168's CHECKs. The store checks
// first; a CHECK violation from Postgres is joined to it.
var ErrRealmBad = errors.New("store: invalid personal realm value")

// The ranges of rdb 0168's CHECKs. A nil limit is off.
const (
	RealmDayLimitMin   = 60
	RealmDayLimitMax   = 1440
	RealmWeekLimitMin  = 60
	RealmWeekLimitMax  = 10080
	RealmCommPrefsMax  = 4096 // bytes of the comm_prefs object
	realmWorkspaceIDMx = 200
)

// RealmProfile is personal.profile. "" = NULL: no zone (the browser's, 118
// C4), no locale. CommPrefs is a JSON object, "{}" when none.
type RealmProfile struct {
	TimeZone  string
	Locale    string
	CommPrefs json.RawMessage
	UpdatedAt time.Time
}

// RealmLimits is one personal.settings row: the hours limits in force from
// ValidFrom (YYYY-MM-DD) on. nil = off.
type RealmLimits struct {
	ValidFrom        string
	DayLimitMinutes  *int
	WeekLimitMinutes *int
	UpdatedAt        time.Time
}

// RealmReceipt is one personal.hours_receipts row (8.2). ApproverName ""
// and a nil DecidedAt are NULL.
type RealmReceipt struct {
	WorkspaceID   string
	WorkspaceName string
	Day           string
	Minutes       int
	Label         string
	Kind          string
	PeriodStart   string
	PeriodEnd     string
	ApprovalState string
	ApproverName  string
	DecidedAt     *time.Time
	Rev           int
	CopiedAt      time.Time
}

// Realm is implemented by Memory and Postgres. person is the session's own
// HUM-*; anything else is ErrNoPerson before any SQL.
type Realm interface {
	// RealmProfileOf is the person's profile; the zero profile (CommPrefs
	// "{}") when none was ever put.
	RealmProfileOf(ctx context.Context, person string) (RealmProfile, error)
	// PutRealmProfile writes the whole profile. ErrNotFound: no such human.
	PutRealmProfile(ctx context.Context, person string, p RealmProfile, now time.Time) error
	// AppendRealmLimits adds the limits in force from l.ValidFrom; a second
	// change on the same day replaces that day's row. ErrNotFound: no such
	// human.
	AppendRealmLimits(ctx context.Context, person string, l RealmLimits, now time.Time) error
	// RealmLimitsHistory is every limits row, oldest valid_from first.
	RealmLimitsHistory(ctx context.Context, person string) ([]RealmLimits, error)
	// RealmLimitsOn is the row in force on day (the newest valid_from <=
	// day); false when none is.
	RealmLimitsOn(ctx context.Context, person, day string) (RealmLimits, bool, error)
	// RealmReceipts is the person's receipts, the newest rev per (workspace,
	// day, label, kind), by workspace, day, label, kind.
	RealmReceipts(ctx context.Context, person string) ([]RealmReceipt, error)
	// DeleteRealmReceipts erases every rev of the person's receipts of one
	// workspace and closes its receipt_due row (8.3); the rows removed.
	DeleteRealmReceipts(ctx context.Context, person, workspaceID string) (int, error)
}

var (
	_ Realm = (*Memory)(nil)
	_ Realm = (*Postgres)(nil)
)

// normalizeRealmProfile checks p against rdb 0168 and fills CommPrefs "{}".
func normalizeRealmProfile(p RealmProfile) (RealmProfile, error) {
	if p.TimeZone != "" && !auth.IsTimeZone(p.TimeZone) {
		return p, fmt.Errorf("%w: time_zone must be an IANA zone name", ErrRealmBad)
	}
	if err := checkLocale(p.Locale); err != nil {
		return p, fmt.Errorf("%w: %v", ErrRealmBad, err)
	}
	if len(p.CommPrefs) == 0 {
		p.CommPrefs = json.RawMessage(`{}`)
	}
	var obj map[string]any
	if err := json.Unmarshal(p.CommPrefs, &obj); err != nil || obj == nil {
		return p, fmt.Errorf("%w: comm_prefs must be a JSON object", ErrRealmBad)
	}
	if len(p.CommPrefs) > RealmCommPrefsMax {
		return p, fmt.Errorf("%w: comm_prefs above %d bytes", ErrRealmBad, RealmCommPrefsMax)
	}
	return p, nil
}

// checkRealmLimits checks l against rdb 0168.
func checkRealmLimits(l RealmLimits) error {
	if err := checkRealmDay(l.ValidFrom); err != nil {
		return err
	}
	if d := l.DayLimitMinutes; d != nil && (*d < RealmDayLimitMin || *d > RealmDayLimitMax) {
		return fmt.Errorf("%w: day limit outside %d..%d minutes", ErrRealmBad, RealmDayLimitMin, RealmDayLimitMax)
	}
	if w := l.WeekLimitMinutes; w != nil && (*w < RealmWeekLimitMin || *w > RealmWeekLimitMax) {
		return fmt.Errorf("%w: week limit outside %d..%d minutes", ErrRealmBad, RealmWeekLimitMin, RealmWeekLimitMax)
	}
	return nil
}

// checkRealmDay checks a YYYY-MM-DD day.
func checkRealmDay(day string) error {
	if _, err := time.Parse(time.DateOnly, day); err != nil {
		return fmt.Errorf("%w: day must be YYYY-MM-DD", ErrRealmBad)
	}
	return nil
}

// checkRealmWorkspace checks a receipt's workspace id (rdb 0168: 1..200).
func checkRealmWorkspace(ws string) error {
	if ws == "" || len(ws) > realmWorkspaceIDMx {
		return fmt.Errorf("%w: workspace id must be 1..%d bytes", ErrRealmBad, realmWorkspaceIDMx)
	}
	return nil
}
