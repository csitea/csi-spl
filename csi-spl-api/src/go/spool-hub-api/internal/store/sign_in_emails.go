package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// A person signs in with more than one email (owner HUM-10, t1 f265541a, msg
// cca0746d): "Only the admin of a workspace can add other emails to other
// users, but before they can use them, they must authenticate with them
// against the cloud provider."
//
// An address of a human is ACTIVE when a verified human_identities row of
// that human carries it: it links a new provider identity (findHuman) and
// matches an invite (admitTx). It is PENDING when a workspace admin added it
// (rdb 0167 human_pending_emails) and no provider has proved it yet: it signs
// nobody in and matches no invite. A cloud-provider sign-in that asserts it
// verified, started from that human's own signed-in session (a link, auth
// start?link=1), links to the human and turns it active; a cold sign-in
// never does. humans.email,
// the main address, never changes through any of this.

// Sign-in email states.
const (
	EmailActive  = "active"
	EmailPending = "pending"
)

// SignInEmail is one address of a human: its state, the providers whose
// verified identity carries it (active only, sorted), and whether it is the
// main address (humans.email).
type SignInEmail struct {
	Email     string   `json:"email"`
	State     string   `json:"state"`
	Providers []string `json:"providers"`
	Main      bool     `json:"main"`
}

var (
	// ErrEmailTaken: the address is active or pending on ANOTHER human. The
	// caller answers 409 and never says whose it is; there is no merge.
	ErrEmailTaken = errors.New("store: the address belongs to another account")
	// ErrLastSignIn: removing the address would leave the human no identity
	// that can sign in.
	ErrLastSignIn = errors.New("store: the last sign-in of a human cannot be removed")
	// ErrTechnicalHuman: an agent or an act-as clone (humans.technical)
	// signs nobody in, so it takes no address.
	ErrTechnicalHuman = errors.New("store: a technical human has no sign-in emails")
	// ErrMainEmail: the main address (humans.email) is not removed here.
	ErrMainEmail = errors.New("store: the main address cannot be removed")
)

// SignInEmails is the store side of the admin's "sign-in emails" of a member.
type SignInEmails interface {
	// SignInEmails lists hum's active and pending addresses, the main one
	// first, then by address. An unknown human is ErrNotFound.
	SignInEmails(ctx context.Context, hum string) ([]SignInEmail, error)
	// AddPendingEmail adds email (lower-cased, validated by the caller) to
	// hum as pending; addedIn / addedBy are the workspace and the admin. It
	// answers the address's state on hum: pending when added or already
	// pending, active when hum already proved it (nothing is written).
	// Active or pending on another human = ErrEmailTaken; an unknown human =
	// ErrNotFound; an agent or clone = ErrTechnicalHuman (Postgres).
	AddPendingEmail(ctx context.Context, hum, email, addedIn, addedBy string, now time.Time) (string, error)
	// RemoveSignInEmail removes a pending address, or an active one with
	// every identity of hum that carries it. Not an address of hum =
	// ErrNotFound; humans.email = ErrMainEmail; the last identity that can
	// sign in = ErrLastSignIn.
	RemoveSignInEmail(ctx context.Context, hum, email string) error
}

// activatesPending reports whether a sign-in at provider may turn a pending
// address active: a cloud provider that proved the mailbox. A native
// password is verified by a mail the hub sent itself, and an operator
// identity signs nobody in, so neither does (t1 f265541a, msg cca0746d).
func activatesPending(provider string) bool {
	return provider != ProviderNative && provider != ProviderOperator && provider != ""
}

// signsIn reports whether an identity of provider is a way in: an operator
// row carries a verified address but cannot itself sign in.
func signsIn(provider string) bool { return provider != ProviderOperator }

func sortEmails(out []SignInEmail) {
	sort.SliceStable(out, func(a, b int) bool {
		if out[a].Main != out[b].Main {
			return out[a].Main
		}
		return out[a].Email < out[b].Email
	})
}

func (s *Postgres) SignInEmails(ctx context.Context, hum string) ([]SignInEmail, error) {
	var main string
	err := s.pool.QueryRow(ctx, `SELECT coalesce(email, '') FROM humans WHERE human_id = $1`, hum).Scan(&main)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	rows, err := s.pool.Query(ctx, `SELECT email, $2::text, array_agg(DISTINCT provider ORDER BY provider)
		FROM human_identities WHERE human_id = $1 AND email_verified AND email IS NOT NULL GROUP BY email
		UNION ALL
		SELECT email, $3::text, '{}'::text[] FROM human_pending_emails WHERE human_id = $1`,
		hum, EmailActive, EmailPending)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []SignInEmail{}
	for rows.Next() {
		var e SignInEmail
		if err := rows.Scan(&e.Email, &e.State, &e.Providers); err != nil {
			return nil, err
		}
		e.Main = e.Email == main
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	sortEmails(out)
	return out, nil
}

func (s *Postgres) AddPendingEmail(ctx context.Context, hum, email, addedIn, addedBy string, now time.Time) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// The address lock Admit takes (lockIdentity): a first sign-in of this
	// address in flight cannot link elsewhere between the check and the add.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('@email|' || $1, 0))`, email); err != nil {
		return "", err
	}
	var technical bool
	if err := tx.QueryRow(ctx, `SELECT technical FROM humans WHERE human_id = $1`, hum).Scan(&technical); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return "", ErrNotFound
		}
		return "", err
	}
	if technical {
		return "", ErrTechnicalHuman
	}
	var owner, state string
	err = tx.QueryRow(ctx, `SELECT x.human_id, x.state FROM (
		SELECT human_id, $2::text AS state FROM human_identities WHERE email = $1 AND email_verified
		UNION ALL SELECT human_id, $3::text FROM human_pending_emails WHERE email = $1) x
		ORDER BY x.human_id = $4 DESC, x.state LIMIT 1`, email, EmailActive, EmailPending, hum).Scan(&owner, &state)
	switch {
	case err == nil && owner == hum:
		return state, nil
	case err == nil:
		return "", ErrEmailTaken
	case !errors.Is(err, pgx.ErrNoRows):
		return "", err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO human_pending_emails (email, human_id, added_in, added_by, created_at)
		VALUES ($1, $2, $3, $4, $5)`, email, hum, addedIn, addedBy, now); err != nil {
		return "", err
	}
	return EmailPending, tx.Commit(ctx)
}

func (s *Postgres) RemoveSignInEmail(ctx context.Context, hum, email string) error {
	email = strings.ToLower(strings.TrimSpace(email))
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	// Serialise with Admit on this human's identities: a sign-in linking a
	// new identity takes the address lock, so take it for this address too.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtextextended('@email|' || $1, 0))`, email); err != nil {
		return err
	}
	var main string
	if err := tx.QueryRow(ctx, `SELECT coalesce(email, '') FROM humans WHERE human_id = $1 FOR UPDATE`, hum).Scan(&main); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}
	tag, err := tx.Exec(ctx, `DELETE FROM human_pending_emails WHERE email = $1 AND human_id = $2`, email, hum)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 1 {
		return tx.Commit(ctx)
	}
	if email == main {
		return ErrMainEmail
	}
	removed, wayIn, err := deleteIdentitiesOf(ctx, tx, hum, email)
	if err != nil {
		return err
	}
	if removed == 0 {
		return ErrNotFound
	}
	if wayIn {
		var left int
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM human_identities WHERE human_id = $1 AND provider <> $2`,
			hum, ProviderOperator).Scan(&left); err != nil {
			return err
		}
		if left == 0 {
			return ErrLastSignIn // rollback: nothing removed
		}
	}
	return tx.Commit(ctx)
}

// deleteIdentitiesOf deletes hum's identities that carry email: how many, and
// whether one of them could sign in (signsIn).
func deleteIdentitiesOf(ctx context.Context, tx pgx.Tx, hum, email string) (int, bool, error) {
	rows, err := tx.Query(ctx, `DELETE FROM human_identities WHERE human_id = $1 AND email = $2 RETURNING provider`, hum, email)
	if err != nil {
		return 0, false, err
	}
	defer rows.Close()
	n, wayIn := 0, false
	for rows.Next() {
		var p string
		if err := rows.Scan(&p); err != nil {
			return 0, false, err
		}
		n++
		wayIn = wayIn || signsIn(p)
	}
	return n, wayIn, rows.Err()
}

func (s *Memory) SignInEmails(_ context.Context, hum string) ([]SignInEmail, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	h := &s.hum
	h.init()
	m, ok := h.humans[hum]
	if !ok {
		return nil, ErrNotFound
	}
	by := map[string]map[string]bool{}
	for k, id := range h.identities {
		if id.human == hum && id.verified && id.email != "" {
			if by[id.email] == nil {
				by[id.email] = map[string]bool{}
			}
			by[id.email][k[0]] = true
		}
	}
	out := []SignInEmail{}
	for e, provs := range by {
		ps := make([]string, 0, len(provs))
		for p := range provs {
			ps = append(ps, p)
		}
		sort.Strings(ps)
		out = append(out, SignInEmail{Email: e, State: EmailActive, Providers: ps, Main: e == m.email})
	}
	for e, p := range h.pending {
		if p.human == hum {
			out = append(out, SignInEmail{Email: e, State: EmailPending, Providers: []string{}, Main: e == m.email})
		}
	}
	sortEmails(out)
	return out, nil
}

func (s *Memory) AddPendingEmail(_ context.Context, hum, email, addedIn, addedBy string, now time.Time) (string, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	s.mu.Lock()
	defer s.mu.Unlock()
	h := &s.hum
	h.init()
	if _, ok := h.humans[hum]; !ok {
		return "", ErrNotFound
	}
	taken := false
	for _, id := range h.identities {
		if id.verified && id.email == email {
			if id.human == hum {
				return EmailActive, nil
			}
			taken = true
		}
	}
	if p, ok := h.pending[email]; ok {
		if p.human == hum && !taken {
			return EmailPending, nil
		}
		taken = true
	}
	if taken {
		return "", ErrEmailTaken
	}
	h.pending[email] = memPending{human: hum, addedIn: addedIn, addedBy: addedBy, at: now}
	return EmailPending, nil
}

func (s *Memory) RemoveSignInEmail(_ context.Context, hum, email string) error {
	email = strings.ToLower(strings.TrimSpace(email))
	s.mu.Lock()
	defer s.mu.Unlock()
	h := &s.hum
	h.init()
	m, ok := h.humans[hum]
	if !ok {
		return ErrNotFound
	}
	if p, ok := h.pending[email]; ok && p.human == hum {
		delete(h.pending, email)
		return nil
	}
	if email == m.email {
		return ErrMainEmail
	}
	var gone [][2]string
	wayIn, left := false, 0
	for k, id := range h.identities {
		switch {
		case id.human != hum:
		case id.email == email:
			gone = append(gone, k)
			wayIn = wayIn || signsIn(k[0])
		case signsIn(k[0]):
			left++
		}
	}
	if len(gone) == 0 {
		return ErrNotFound
	}
	if wayIn && left == 0 {
		return ErrLastSignIn
	}
	for _, k := range gone {
		delete(h.identities, k)
	}
	return nil
}
