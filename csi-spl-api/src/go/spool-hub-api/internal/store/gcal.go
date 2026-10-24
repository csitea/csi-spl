package store

import (
	"context"
	"errors"
	"time"
)

// Gcal is spec 149's per-member Google Calendar store (rdb 0217, build row
// B2, SPL-3170): one connection per member per workspace, its tokens as
// KMS-sealed ciphertext only, the sync lease and the event map. The store
// never sees a plaintext token: the hub seals before ConnectGcal and
// SetGcalTokens and opens after GcalTokens.
//
// Member isolation inside a workspace is this store's job (spec 149 section
// 3, case C3): every member method takes (tenant, human) and every query
// names both, so a member never reads, syncs or deletes another member's
// connection.
//
// The sync cycle (spec 149 section 2.5, P8) claims a connection with a lease,
// never a row lock held across Google calls. The claimed lease end is the
// cycle's fencing token: every cycle write takes the GcalLease and matches
// `sync_lease_until = <token>`; a write that matches no row returns
// ErrGcalLeaseLost (another instance took the lease, or the member
// re-connected or disconnected) and the cycle stops.
type Gcal interface {
	// ConnectGcal upserts the member's connection on (tenant, human): the
	// Google email, the sealed tokens, status connected, due now, no lease.
	// The calendar, the cursors, the watch channel and the map rows are kept
	// when the Google email is the same, and cleared when it changed.
	ConnectGcal(ctx context.Context, c GcalConnection, tok GcalTokens, now time.Time) (GcalConnection, error)
	// GcalConnection reads the member's connection (never a token);
	// ErrNotFound when the member has none.
	GcalConnection(ctx context.Context, tenant, human string) (GcalConnection, error)
	// GcalTokens reads the member's sealed tokens; ErrNotFound when none.
	GcalTokens(ctx context.Context, tenant, human string) (GcalTokens, error)
	// DeleteGcalConnection deletes the member's connection and its map rows
	// (rdb 0217 cascade) and returns the row as it was, so the hub can stop
	// its watch channel and revoke; ErrNotFound when none.
	DeleteGcalConnection(ctx context.Context, tenant, human string) (GcalConnection, error)
	// MarkGcalDue sets the member's connection due at now ("Sync now", a
	// push); ErrNotFound when none.
	MarkGcalDue(ctx context.Context, tenant, human string, now time.Time) error
	// GcalEventMaps lists the member's map rows, by event id.
	GcalEventMaps(ctx context.Context, tenant, human string) ([]GcalEventMap, error)

	// ClaimGcalConnection takes the lease on the connected connection due
	// longest (due_at <= now, no lease or an expired one) for `lease`, all
	// workspaces (operator scope; never a token). ErrNotFound when none is due.
	ClaimGcalConnection(ctx context.Context, now time.Time, lease time.Duration) (GcalConnection, GcalLease, error)
	// GcalConnectionByWatch finds the connection of a Google push channel,
	// all workspaces (operator scope: the push names no workspace; never a
	// token); ErrNotFound when none.
	GcalConnectionByWatch(ctx context.Context, watchChannelID string) (GcalConnection, error)

	// RenewGcalLease moves the lease end to now + lease and returns the new
	// token (spec 149 2.5: after each page of Google results).
	RenewGcalLease(ctx context.Context, l GcalLease, now time.Time, lease time.Duration) (GcalLease, error)
	// SetGcalTokens stores refreshed sealed tokens.
	SetGcalTokens(ctx context.Context, l GcalLease, tok GcalTokens, now time.Time) error
	// SetGcalCalendar stores the target calendar's Google id.
	SetGcalCalendar(ctx context.Context, l GcalLease, calendarID string, now time.Time) error
	// SetGcalStatus sets connected, error or revoked with its reason.
	SetGcalStatus(ctx context.Context, l GcalLease, status, detail string, now time.Time) error
	// SetGcalWatch stores the push channel; a zero GcalWatch clears it.
	SetGcalWatch(ctx context.Context, l GcalLease, w GcalWatch, now time.Time) error
	// PutGcalEventMap upserts the map row of m.EventID. ErrConflict when
	// another event of the connection already maps to m.GoogleID.
	PutGcalEventMap(ctx context.Context, l GcalLease, m GcalEventMap, now time.Time) error
	// DeleteGcalEventMap deletes the map row of eventID (none is no error).
	DeleteGcalEventMap(ctx context.Context, l GcalLease, eventID string) error
	// FinishGcalSync ends a cycle: stores the cursors, last_synced_at = now,
	// due_at = d.NextDue, and clears the lease.
	FinishGcalSync(ctx context.Context, l GcalLease, d GcalSyncDone, now time.Time) error
}

// GcalConnection is one member's Google connection, without its tokens.
// Times are nil when unset; SyncToken and the watch ids are "" when unset.
type GcalConnection struct {
	ID              string
	Tenant          string
	Human           string
	GoogleEmail     string
	CalendarID      string
	Status          string
	StatusDetail    string
	KMSKeyID        string
	AccessExpiry    time.Time
	SyncToken       string
	OutCursor       *time.Time
	DueAt           time.Time
	SyncLeaseUntil  *time.Time
	WatchChannelID  string
	WatchResourceID string
	WatchExpiry     *time.Time
	LastSyncedAt    *time.Time
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// GcalTokens is a connection's sealed tokens: ciphertext only, the KMS key
// version that wrapped them and when the access token expires.
type GcalTokens struct {
	AccessSealed  string
	RefreshSealed string
	KMSKeyID      string
	AccessExpiry  time.Time
}

// GcalLease is a claimed sync lease: the connection and the fencing token
// (the lease end, as stored: microsecond precision).
type GcalLease struct {
	Tenant       string
	Human        string
	ConnectionID string
	Until        time.Time
}

// GcalWatch is a connection's Google push channel.
type GcalWatch struct {
	ChannelID  string
	ResourceID string
	Expiry     *time.Time
}

// GcalEventMap is one synced event: the Spool event and its Google twin.
type GcalEventMap struct {
	EventID  string
	GoogleID string
	ETag     string
	SyncHash string
	SyncedAt time.Time
}

// GcalSyncDone is what a finished cycle stores.
type GcalSyncDone struct {
	SyncToken string     // "" clears it (a 410, or no inbound half)
	OutCursor *time.Time // nil keeps the stored one
	NextDue   time.Time
}

// Connection statuses (rdb 0217 CHECK).
const (
	GcalConnected = "connected"
	GcalError     = "error"
	GcalRevoked   = "revoked"
)

// ErrGcalLeaseLost: a fenced write matched no row, so this cycle no longer
// holds the connection's lease and must stop (spec 149 2.5).
var ErrGcalLeaseLost = errors.New("store: the google calendar sync lease was lost")

// ErrInvalidGcal: a value rdb 0217's CHECKs would refuse.
var ErrInvalidGcal = errors.New("store: invalid google calendar value")

// gcalLeaseUntil is the lease end as Postgres stores it (microseconds), so
// the token the caller holds equals the stored one in both stores.
func gcalLeaseUntil(now time.Time, lease time.Duration) time.Time {
	return now.Add(lease).UTC().Truncate(time.Microsecond)
}

func gcalStatusOK(status, detail string) bool {
	return (status == GcalConnected || status == GcalError || status == GcalRevoked) && len(detail) <= 500
}

func gcalConnectOK(c GcalConnection, tok GcalTokens) bool {
	return c.Tenant != "" && c.Human != "" && len(c.GoogleEmail) >= 3 && len(c.GoogleEmail) <= 320 &&
		gcalTokensOK(tok)
}

func gcalTokensOK(tok GcalTokens) bool {
	return tok.AccessSealed != "" && tok.RefreshSealed != "" && tok.KMSKeyID != ""
}

func gcalMapOK(m GcalEventMap) bool {
	return calendarIDRe.MatchString(m.EventID) && m.GoogleID != "" && len(m.GoogleID) <= 1024 && len(m.SyncHash) == 64
}
