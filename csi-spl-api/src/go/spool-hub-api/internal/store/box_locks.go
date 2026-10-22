package store

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"sync"
	"time"
)

// The box owner lock's data (spec 025 box-owner-lock.md section 6.1, row B1,
// rdb 0213, SPL-2952). A locked box's agents are reachable only by the lock's
// owners (HUM-*); every write of a lock carries a body signed by the owner's
// lock key K_lock (Ed25519), which only the owner can unseal on the locked
// box. The hub keeps only its public half.
//
// Every load re-verifies the row (VerifyBoxLock): the signature over
// signed_body, and that signed_body is the canonical body of the row's own
// columns. A row edited in the database without K_lock (owners widened, a
// peer box added) loads as Tampered: locked to nobody, one tampered audit
// row. Nothing in this file decides a refusal; the hub's checks (rows B2, B3,
// B5) read IsOwner / IsPeer, which answer false for a tampered lock.

// Audit verdicts of box_lock_audit (rdb 0213's CHECK).
const (
	BoxLockRefused     = "refused"
	BoxLockCreated     = "created"
	BoxLockChanged     = "changed"
	BoxLockLifted      = "lifted"
	BoxLockSealedHello = "sealed_hello"
	BoxLockTamperedRow = "tampered"
)

// BoxLockLoadPath is the audit path of a tamper finding made on a load.
const BoxLockLoadPath = "load"

// boxLockAuditWindow is how long one audit row is bumped instead of a new
// row written (section 6.3: one row per box, human or from_box, path and
// minute), so a refusal loop does not flood the database.
const boxLockAuditWindow = time.Minute

// boxLockCacheTTL bounds how long a lock written by another process is
// served from cache (section 5.2, like the pin cache, hotcache.go).
const boxLockCacheTTL = 5 * time.Second

var (
	// ErrBoxLockTampered: the row does not verify against its own K_lock.
	ErrBoxLockTampered = errors.New("store: box lock does not verify")
	// ErrBoxLockExists: a create for a box that is already locked.
	ErrBoxLockExists = errors.New("store: box is already locked")
	// ErrBoxLockVersion: a change whose version is not the stored one + 1.
	ErrBoxLockVersion = errors.New("store: box lock version must be the stored version + 1")
	// ErrBoxLockKey: a change that names another K_lock than the one on file.
	ErrBoxLockKey = errors.New("store: box lock change is not signed by the lock key on file")
	// ErrBadBoxLockAudit: an audit row with no path or an unknown verdict.
	ErrBadBoxLockAudit = errors.New("store: bad box lock audit row")
)

// BoxLock is one box_locks row. SignedBody is BoxLockBody of the fields
// before it, Signature K_lock's Ed25519 signature over SignedBody; both keys
// and the signature are standard base64.
type BoxLock struct {
	TenantID   string
	BoxID      string
	LockPubKey string
	BoxPubKey  string
	Owners     []string
	PeerBoxes  []string
	HidePosts  bool
	Version    int64
	SignedBody string
	Signature  string
	CreatedAt  time.Time
	UpdatedAt  time.Time
	// Tampered is set by a load whose VerifyBoxLock failed: the box is
	// locked to nobody (section 6.1). Never written.
	Tampered bool
}

// IsOwner reports whether hum may reach the box: false for every human
// when the lock is tampered.
func (l *BoxLock) IsOwner(hum string) bool {
	return l != nil && !l.Tampered && hum != "" && slices.Contains(l.Owners, hum)
}

// IsPeer reports whether box may send to the locked box (OQ-2): false for
// every box when the lock is tampered.
func (l *BoxLock) IsPeer(box string) bool {
	return l != nil && !l.Tampered && box != "" && slices.Contains(l.PeerBoxes, box)
}

// clone copies l with its own slices.
func (l *BoxLock) clone() *BoxLock {
	if l == nil {
		return nil
	}
	c := *l
	c.Owners, c.PeerBoxes = slices.Clone(l.Owners), slices.Clone(l.PeerBoxes)
	return &c
}

// boxLockBody is the canonical body: the columns of box_locks before
// signed_body, in their rdb order, under their column names.
type boxLockBody struct {
	TenantID   string   `json:"tenant_id"`
	BoxID      string   `json:"box_id"`
	LockPubKey string   `json:"lock_pubkey"`
	BoxPubKey  string   `json:"box_pubkey"`
	Owners     []string `json:"owners"`
	PeerBoxes  []string `json:"peer_boxes"`
	HidePosts  bool     `json:"hide_posts"`
	Version    int64    `json:"version"`
}

// BoxLockBody is the canonical JSON K_lock signs for l: encoding/json of the
// columns before signed_body, in rdb order, an empty list as []. The box side
// (spool lock sign, row B4) signs exactly these bytes.
func BoxLockBody(l BoxLock) string {
	b := boxLockBody{TenantID: l.TenantID, BoxID: l.BoxID, LockPubKey: l.LockPubKey, BoxPubKey: l.BoxPubKey,
		Owners: l.Owners, PeerBoxes: l.PeerBoxes, HidePosts: l.HidePosts, Version: l.Version}
	if b.Owners == nil {
		b.Owners = []string{}
	}
	if b.PeerBoxes == nil {
		b.PeerBoxes = []string{}
	}
	out, err := json.Marshal(b)
	if err != nil { // strings, bools and an int never fail to marshal
		panic(err)
	}
	return string(out)
}

// VerifyBoxLock checks l against its own K_lock: the key and signature
// decode, the signature holds over SignedBody, SignedBody is BoxLockBody(l),
// and the lock has an owner and a version. Any failure is
// ErrBoxLockTampered with the reason.
func VerifyBoxLock(l BoxLock) error {
	pub, err := base64.StdEncoding.DecodeString(l.LockPubKey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return fmt.Errorf("%w: lock_pubkey is not a base64 Ed25519 key", ErrBoxLockTampered)
	}
	sig, err := base64.StdEncoding.DecodeString(l.Signature)
	if err != nil || len(sig) != ed25519.SignatureSize {
		return fmt.Errorf("%w: signature is not a base64 Ed25519 signature", ErrBoxLockTampered)
	}
	if !ed25519.Verify(ed25519.PublicKey(pub), []byte(l.SignedBody), sig) {
		return fmt.Errorf("%w: signature does not hold over signed_body", ErrBoxLockTampered)
	}
	if l.SignedBody != BoxLockBody(l) {
		return fmt.Errorf("%w: signed_body differs from the row", ErrBoxLockTampered)
	}
	if len(l.Owners) == 0 || l.Version < 1 {
		return fmt.Errorf("%w: no owner or no version", ErrBoxLockTampered)
	}
	return nil
}

// checkBoxLockChange is the change rule over the stored lock prev: the same
// K_lock (a body signed by another key never replaces the lock) and the next
// version.
func checkBoxLockChange(prev, next BoxLock) error {
	if next.LockPubKey != prev.LockPubKey {
		return ErrBoxLockKey
	}
	if next.Version != prev.Version+1 {
		return fmt.Errorf("%w: stored %d, got %d", ErrBoxLockVersion, prev.Version, next.Version)
	}
	return nil
}

// BoxLockAudit is one box_lock_audit row: HumanID and FromBox are "" when
// not known (NULL in rdb).
type BoxLockAudit struct {
	TenantID string
	BoxID    string
	HumanID  string
	FromBox  string
	Path     string
	Verdict  string
	FirstAt  time.Time
	LastAt   time.Time
	Count    int
}

// checkBoxLockAudit validates a row before any write.
func checkBoxLockAudit(a BoxLockAudit) error {
	if err := checkTenant(a.TenantID); err != nil {
		return err
	}
	switch a.Verdict {
	case BoxLockRefused, BoxLockCreated, BoxLockChanged, BoxLockLifted, BoxLockSealedHello, BoxLockTamperedRow:
	default:
		return fmt.Errorf("%w: verdict %q", ErrBadBoxLockAudit, a.Verdict)
	}
	if a.BoxID == "" || a.Path == "" {
		return fmt.Errorf("%w: no box or path", ErrBadBoxLockAudit)
	}
	return nil
}

// sameAuditKey reports whether row r is bumped by a at now: same box,
// human, from_box, path and verdict, first written within the window.
func sameAuditKey(r, a BoxLockAudit, now time.Time) bool {
	return r.TenantID == a.TenantID && r.BoxID == a.BoxID && r.HumanID == a.HumanID && r.FromBox == a.FromBox &&
		r.Path == a.Path && r.Verdict == a.Verdict && r.FirstAt.After(now.Add(-boxLockAuditWindow))
}

// BoxLockStore is implemented by Memory and Postgres.
type BoxLockStore interface {
	// BoxLock reads the box's lock, verified: nil, nil = the box is not
	// locked. A row that fails VerifyBoxLock comes back with Tampered set
	// and writes one tampered audit row. On an error the caller refuses
	// (section 5.2: fail closed). Postgres serves it through a 5 s cache.
	BoxLock(ctx context.Context, tenant, box string) (*BoxLock, error)
	// CreateBoxLock writes a new lock after VerifyBoxLock, and a created
	// audit row by human by. ErrBoxLockExists: the box is already locked.
	CreateBoxLock(ctx context.Context, l BoxLock, by string, now time.Time) error
	// ChangeBoxLock replaces the lock after VerifyBoxLock, signed by the
	// K_lock on file at the stored version + 1, and writes a changed audit
	// row. ErrNotFound: no lock.
	ChangeBoxLock(ctx context.Context, l BoxLock, by string, now time.Time) error
	// LiftBoxLock deletes the lock and writes a lifted audit row. The
	// lift statement's K_lock signature is the route's check (row B2).
	// ErrNotFound: no lock.
	LiftBoxLock(ctx context.Context, tenant, box, by string, now time.Time) error
	// RecordBoxLockAudit writes a row, or bumps the one of the same key
	// written within the last minute (section 6.3).
	RecordBoxLockAudit(ctx context.Context, a BoxLockAudit, now time.Time) error
	// BoxLockAudits reads the box's audit rows, newest first, at most limit.
	BoxLockAudits(ctx context.Context, tenant, box string, limit int) ([]BoxLockAudit, error)
}

var (
	_ BoxLockStore = (*Memory)(nil)
	_ BoxLockStore = (*Postgres)(nil)
)

// verifyLoaded marks a loaded row Tampered when it fails VerifyBoxLock and
// answers whether a tamper audit row is due.
func verifyLoaded(l *BoxLock) (tampered bool) {
	if l == nil {
		return false
	}
	l.Tampered = VerifyBoxLock(*l) != nil
	return l.Tampered
}

// tamperAudit is the audit row of a tamper finding on a load.
func tamperAudit(l *BoxLock) BoxLockAudit {
	return BoxLockAudit{TenantID: l.TenantID, BoxID: l.BoxID, Path: BoxLockLoadPath, Verdict: BoxLockTamperedRow}
}

// boxLockCache holds verified loads per (tenant, box), the lock or its
// absence, for boxLockCacheTTL. A write through the same store clears it
// after its commit; gen keeps a load that raced a write from storing what it
// read before it (as hotCache).
type boxLockCache struct {
	mu  sync.Mutex
	gen uint64
	m   map[[2]string]hotEntry[*BoxLock]
}

func (c *boxLockCache) generation() uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.gen
}

func (c *boxLockCache) forget() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.gen++
	c.m = nil
}

// get answers a copy of the cached lock (nil = not locked) and whether one
// was cached and fresh.
func (c *boxLockCache) get(tenant, box string) (*BoxLock, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[[2]string{tenant, box}]
	if !ok || !hotNow().Before(e.exp) {
		return nil, false
	}
	return e.v.clone(), true
}

func (c *boxLockCache) put(gen uint64, tenant, box string, l *BoxLock) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if gen != c.gen {
		return
	}
	if c.m == nil {
		c.m = map[[2]string]hotEntry[*BoxLock]{}
	}
	c.m[[2]string{tenant, box}] = hotEntry[*BoxLock]{v: l.clone(), exp: hotNow().Add(boxLockCacheTTL)}
}
