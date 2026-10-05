package store

import (
	"cmp"
	"context"
	"fmt"
	"slices"
	"time"
)

// Demo post audit (rdb 0131, specs/077 FR-011, T025): one row per post and
// per edit a demo_user makes in the demo workspace, with the identity that
// made it snapshotted at write time. The 3-hour sweep deletes the visitor's
// humans row and identities, and the nightly wipe deletes the messages; this
// record outlives both (no foreign key to either). Append-only: the store
// has no update and no delete; the retention purge is the named action
// csi-spl-orc do_spl_demo_audit_purge.

// Demo audit actions (demo_post_audit.action).
const (
	DemoAuditPost = "post" // a send or a reply: one row per msg id, a resend writes nothing
	DemoAuditEdit = "edit" // an edit of the visitor's own message: one row per edit
)

// DemoAuditMaxLimit caps one page of DemoAuditRows.
const DemoAuditMaxLimit = 500

// DemoAudit is one demo_post_audit row. On AppendDemoAudit the identity
// fields (Pseudonym, Provider, Subject, Email) are ignored: the store reads
// them from HumanID's humans / human_identities rows in the same write.
type DemoAudit struct {
	ID        int64
	At        time.Time
	TenantID  string
	Action    string
	HumanID   string
	Pseudonym string // humans.display_name: the visitor's pseudonym (077 T011)
	Provider  string // the identity's provider (google, facebook, ...)
	Subject   string // the provider's id of the person
	Email     string // the provider-VERIFIED address, else ""
	MsgID     string
	TaskID    string
	Channel   string // "" = a DM
	To        string // the recipient (an agent or a person), "" = the channel
	Body      string
}

// DemoAuditor is implemented by Memory and Postgres.
type DemoAuditor interface {
	// AppendDemoAudit writes e, its identity read from e.HumanID's rows. A
	// post whose (tenant, msg id) is already audited writes nothing.
	AppendDemoAudit(ctx context.Context, e DemoAudit) error
	// DemoAuditRows is tenant's rows newest first, at most limit (1 ..
	// DemoAuditMaxLimit), only those with an id below before when before > 0.
	DemoAuditRows(ctx context.Context, tenant string, before int64, limit int) ([]DemoAudit, error)
}

var (
	_ DemoAuditor = (*Memory)(nil)
	_ DemoAuditor = (*Postgres)(nil)
)

// checkDemoAudit is the Go side of rdb 0131's CHECKs.
func checkDemoAudit(e DemoAudit) error {
	if err := checkTenant(e.TenantID); err != nil {
		return err
	}
	if e.Action != DemoAuditPost && e.Action != DemoAuditEdit {
		return fmt.Errorf("demo audit: action %q is not post or edit", e.Action)
	}
	if e.HumanID == "" || e.MsgID == "" {
		return fmt.Errorf("demo audit: a human and a msg id are required")
	}
	return nil
}

// demoAuditLimit clamps a page size.
func demoAuditLimit(limit int) int {
	return min(max(limit, 1), DemoAuditMaxLimit)
}

// Memory side: a per-store slice beside the Memory struct, guarded by s.mu.
var memDemoAudits = map[*Memory][]DemoAudit{}

func (s *Memory) AppendDemoAudit(_ context.Context, e DemoAudit) error {
	if err := checkDemoAudit(e); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rows := memDemoAudits[s]
	if e.Action == DemoAuditPost && slices.ContainsFunc(rows, func(r DemoAudit) bool {
		return r.TenantID == e.TenantID && r.MsgID == e.MsgID && r.Action == DemoAuditPost
	}) {
		return nil
	}
	e.Pseudonym, e.Provider, e.Subject, e.Email = s.demoAuditIdentity(e.HumanID)
	e.ID = int64(len(rows) + 1)
	e.At = e.At.UTC().Truncate(time.Microsecond)
	memDemoAudits[s] = append(rows, e)
	return nil
}

// demoAuditIdentity is hum's display name and its first identity in
// (provider, subject) order, the email only when the provider verified it.
// s.mu is held.
func (s *Memory) demoAuditIdentity(hum string) (name, provider, subject, email string) {
	s.hum.init()
	if h := s.hum.humans[hum]; h != nil {
		name = h.name
	}
	var keys [][2]string
	for k, id := range s.hum.identities {
		if id.human == hum {
			keys = append(keys, k)
		}
	}
	if len(keys) == 0 {
		return name, "", "", ""
	}
	slices.SortFunc(keys, func(a, b [2]string) int {
		return cmp.Or(cmp.Compare(a[0], b[0]), cmp.Compare(a[1], b[1]))
	})
	id := s.hum.identities[keys[0]]
	if id.verified {
		email = id.email
	}
	return name, keys[0][0], keys[0][1], email
}

func (s *Memory) DemoAuditRows(_ context.Context, tenant string, before int64, limit int) ([]DemoAudit, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	limit = demoAuditLimit(limit)
	s.mu.Lock()
	defer s.mu.Unlock()
	rows := memDemoAudits[s]
	var out []DemoAudit
	for i := len(rows) - 1; i >= 0 && len(out) < limit; i-- {
		if r := rows[i]; r.TenantID == tenant && (before <= 0 || r.ID < before) {
			out = append(out, r)
		}
	}
	return out, nil
}
