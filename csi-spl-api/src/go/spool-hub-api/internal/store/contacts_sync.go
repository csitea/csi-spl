package store

import (
	"context"
	"errors"
	"time"
	"unicode/utf8"
)

// The contacts binding store (spec 154 v1.1 sections 2.2, 2.6 and 3, build
// row B2) over rdb 0226's contacts_sync: one binding per person (its
// primary key human_id), in the workspace whose Google connection it syncs.
// It is a workspace table that holds no contact value: the member calls run
// in the binding's workspace scope, and the two calls that cannot name the
// workspace run under the operator scope (operatorCallers): the read of a
// person's binding wherever it is (seat note N4, the hub's "Erase one") and
// the purge's status line (W4, C2e). No call here opens the person scope;
// the contacts themselves are personal_contacts.go's.
//
// The sync cycle's half (spec 154 v1.2 section 2.5, build row B8a) is spec
// 149 2.5's lease applied to contacts_sync: the claim runs under the
// operator scope (one more operatorCallers entry), takes the enabled
// binding due longest whose Google connection is connected and which is
// not in backoff, and returns the lease end as the cycle's fencing token.
// Every later write of the cycle (the renewal after each page, the backoff
// line, the finish) runs in the binding's own workspace scope,
// inTenant(lease.Tenant), and matches sync_lease_until = <token>; a write
// that matches no row is ErrContactsLeaseLost and the cycle stops. The
// lease is the binding's own, never the calendar's (spec 2.5 "State").

// ErrContactsSyncElsewhere: the person's binding is in another workspace
// (spec 2.2 step 3, 409 contacts_sync_elsewhere). Only the person's own row
// is told about, and only that it exists.
var ErrContactsSyncElsewhere = errors.New("store: the person's contacts sync is on in another workspace")

// ErrContactsSyncBusy: a sync of the binding holds its lease (spec 4, 409
// sync_in_progress).
var ErrContactsSyncBusy = errors.New("store: a contacts sync is in progress")

// ContactsPurgePendingDetail is the status line MarkContactsPurgePending
// sets (spec 2.6, C7c): no contact value, within rdb 0226's 500 characters.
const ContactsPurgePendingDetail = "Contacts deleted in Spool were purged after 30 days before their delete reached Google."

// ErrContactsLeaseLost: a fenced write matched no row, so this cycle no
// longer holds the binding's lease (another instance took it, or the
// binding ended) and must stop (spec 2.5, as 149's ErrGcalLeaseLost).
var ErrContactsLeaseLost = errors.New("store: the contacts sync lease was lost")

// ErrContactsSyncBad: a value rdb 0226's CHECKs on contacts_sync refuse.
var ErrContactsSyncBad = errors.New("store: invalid contacts sync value")

// ContactsStatusDetailMax is rdb 0226's status_detail CHECK, in characters.
const ContactsStatusDetailMax = 500

// ContactsLease is a claimed contacts sync lease: the binding and the
// fencing token (the lease end as stored, microsecond precision).
type ContactsLease struct {
	Tenant string
	Human  string
	Until  time.Time
}

// ContactsSyncDone is what a finished cycle stores.
type ContactsSyncDone struct {
	SyncToken string     // "" clears it (an expired token, spec 2.5)
	OutCursor *time.Time // nil keeps the stored one
	NextDue   time.Time
}

// ContactsSync is one contacts_sync row. SyncToken "" = NULL.
type ContactsSync struct {
	Human          string
	Tenant         string
	Enabled        bool
	SyncToken      string
	OutCursor      *time.Time
	DueAt          time.Time
	SyncLeaseUntil *time.Time
	BackoffUntil   *time.Time
	StatusDetail   string
	LastSyncedAt   *time.Time
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// ContactsSyncs is implemented by Memory and Postgres. human is a HUM-*;
// anything else is ErrNoPerson before any SQL. ErrNotFound: no binding of
// the human (in that workspace, for the member calls).
type ContactsSyncs interface {
	// ContactsSyncIn is the human's binding in tenant.
	ContactsSyncIn(ctx context.Context, tenant, human string) (ContactsSync, error)
	// SetContactsSync is the Contacts switch in tenant (spec 2.2 step 3):
	// on updates the binding there, else inserts it, due now;
	// ErrContactsSyncElsewhere when it is in another workspace, ErrNotFound
	// when tenant holds no Google connection or no seat of the human. Off
	// updates the binding there only (ErrNotFound with none), as the
	// person's erase does in each workspace (spec 2.6, C8e).
	SetContactsSync(ctx context.Context, tenant, human string, enabled bool, now time.Time) (ContactsSync, error)
	// MarkContactsSyncDue is "Sync now": the enabled binding in tenant is
	// due at now. ErrContactsSyncBusy while a sync holds its lease.
	MarkContactsSyncDue(ctx context.Context, tenant, human string, now time.Time) error
	// ContactsSyncOf is the human's binding in whichever workspace it is
	// (operator scope, N4): the hub's "Erase one" asks whether a Google
	// delete must be sent (spec 2.6).
	ContactsSyncOf(ctx context.Context, human string) (ContactsSync, error)
	// MarkContactsPurgePending sets ContactsPurgePendingDetail on the
	// binding of each of persons (operator scope, W4); the bindings changed.
	MarkContactsPurgePending(ctx context.Context, persons []string, now time.Time) (int, error)

	// ClaimContactsSync takes the lease on the enabled binding due longest
	// (due_at <= now, no lease or an expired one, no backoff_until after
	// now) whose gcal_connections row is connected, for lease, all
	// workspaces (operator scope). ErrNotFound when none is due.
	ClaimContactsSync(ctx context.Context, now time.Time, lease time.Duration) (ContactsSync, ContactsLease, error)
	// RenewContactsLease moves the lease end to now + lease and returns the
	// new token (spec 2.5: after each page of Google results).
	RenewContactsLease(ctx context.Context, l ContactsLease, now time.Time, lease time.Duration) (ContactsLease, error)
	// SetContactsBackoff stores backoff_until (nil clears it) and the
	// status line (spec 2.5 "Rate limits": a 429 or 503). ErrContactsSyncBad
	// for a line above ContactsStatusDetailMax characters.
	SetContactsBackoff(ctx context.Context, l ContactsLease, until *time.Time, detail string, now time.Time) error
	// FinishContactsSync ends a cycle: stores the cursors, last_synced_at =
	// now, due_at = d.NextDue, and clears the lease. The backoff and the
	// status line are SetContactsBackoff's, never cleared here.
	FinishContactsSync(ctx context.Context, l ContactsLease, d ContactsSyncDone, now time.Time) error
}

var (
	_ ContactsSyncs = (*Memory)(nil)
	_ ContactsSyncs = (*Postgres)(nil)
)

// contactsLeaseOK is a lease that names a binding; anything else matches no
// row, so it is ErrContactsLeaseLost before any SQL.
func contactsLeaseOK(l ContactsLease) bool {
	return checkPerson(l.Human) == nil && l.Tenant != "" && !l.Until.IsZero()
}

// contactsDetailOK is rdb 0226's status_detail CHECK.
func contactsDetailOK(detail string) bool {
	return utf8.RuneCountInString(detail) <= ContactsStatusDetailMax && utf8.ValidString(detail)
}

// checkContactsSyncPersons is checkPerson on each of persons.
func checkContactsSyncPersons(persons []string) error {
	for _, p := range persons {
		if err := checkPerson(p); err != nil {
			return err
		}
	}
	return nil
}
