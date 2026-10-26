package store

import (
	"context"
	"errors"
	"time"
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
}

var (
	_ ContactsSyncs = (*Memory)(nil)
	_ ContactsSyncs = (*Postgres)(nil)
)

// checkContactsSyncPersons is checkPerson on each of persons.
func checkContactsSyncPersons(persons []string) error {
	for _, p := range persons {
		if err := checkPerson(p); err != nil {
			return err
		}
	}
	return nil
}
