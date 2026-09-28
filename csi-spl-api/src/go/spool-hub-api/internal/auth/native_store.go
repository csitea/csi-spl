package auth

import (
	"context"
	"errors"
	"sync"
	"time"
)

// ProviderPassword is the provider slug of a native credential: the session's
// `p` claim and the human_identities.provider the Registrar stores (rdb 0006).
const ProviderPassword = "password"

// Token kinds a CredStore issues.
const (
	TokenVerify = "verify"
	TokenReset  = "reset"
)

// Errors from a CredStore.
var (
	ErrCredNotFound = errors.New("auth: no such credential")
	// ErrTokenInvalid: unknown, consumed, or (for reset) expired.
	ErrTokenInvalid = errors.New("auth: token invalid")
	// ErrTokenExpired: a verification token that exists but is past its expiry.
	ErrTokenExpired = errors.New("auth: token expired")
	// ErrVerifyPasswordMismatch: the verify click did not carry the password the
	// link was issued for. Nothing is written or consumed.
	ErrVerifyPasswordMismatch = errors.New("auth: password does not match the link")
)

// Credential is one password_credentials row (rdb 0009). Subject is the
// lower-cased email.
type Credential struct {
	Subject         string
	PasswordHash    string
	DisplayName     string
	EmailVerifiedAt *time.Time
	CreatedAt       time.Time
	// Locale is the locale the account was registered in (rdb 0017
	// password_credentials.preferred_locale), "" when unknown. Set by
	// CreateCredential only; a repeat register leaves it.
	Locale string
}

// Verified reports whether the address has been proven.
func (c Credential) Verified() bool { return c.EmailVerifiedAt != nil }

// MailFloor is the per-account ceiling on mails of one kind (015 FR-006a).
type MailFloor struct {
	MinInterval time.Duration
	MaxPerDay   int
}

// CredStore persists native credentials and their hashed tokens (spec 015).
// Token arguments are ALWAYS sha256 hex digests, never plaintext.
type CredStore interface {
	// CreateCredential inserts the credential; created=false (nil error) when
	// the subject already has one, which is left untouched.
	CreateCredential(ctx context.Context, c Credential, now time.Time) (created bool, err error)
	GetCredential(ctx context.Context, subject string) (Credential, error)
	// IssueToken stores a token of kind for subject unless the floor refuses
	// (issued=false, nil error). Counting and insert are one atomic step.
	// pwHash is required for TokenVerify (the password of the register call
	// that minted it) and ignored for TokenReset. A new TokenVerify retires
	// every older live one of the subject: only the newest link verifies.
	IssueToken(ctx context.Context, kind, subject, tokenHash, pwHash string, now, expires time.Time, floor MailFloor) (issued bool, err error)
	// ConsumeVerification installs the token's password hash, marks the
	// credential verified and consumes every live verification token of it. A
	// token of an already-verified credential is a success that changes
	// nothing (repeat click). ErrTokenInvalid / ErrTokenExpired otherwise.
	//
	// accept is asked with the token's password hash before anything is
	// written: false = ErrVerifyPasswordMismatch, nothing consumed. The click proves
	// the MAILBOX; accept proves the clicker is also the person who chose
	// that password, else anyone could register a victim's address with
	// their own password and have the victim's click verify it.
	ConsumeVerification(ctx context.Context, tokenHash string, now time.Time, accept func(pwHash string) bool) error
	// ConsumeReset sets newHash, marks the email verified and consumes every
	// live reset token of the credential. Returns the subject.
	ConsumeReset(ctx context.Context, tokenHash, newHash string, now time.Time) (subject string, err error)
	SetPassword(ctx context.Context, subject, newHash string, now time.Time) error
	TouchLogin(ctx context.Context, subject string, now time.Time) error
}

type memToken struct {
	kind, subject, pwHash string
	created, expires      time.Time
	consumed              bool
}

// MemoryCredStore is the in-process CredStore (tests, `memory:` lde runs).
type MemoryCredStore struct {
	mu     sync.Mutex
	creds  map[string]Credential
	tokens map[string]*memToken
}

// NewMemoryCredStore returns an empty store.
func NewMemoryCredStore() *MemoryCredStore {
	return &MemoryCredStore{creds: map[string]Credential{}, tokens: map[string]*memToken{}}
}

func (m *MemoryCredStore) CreateCredential(_ context.Context, c Credential, now time.Time) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.creds[c.Subject]; ok {
		return false, nil
	}
	c.CreatedAt = now
	m.creds[c.Subject] = c
	return true, nil
}

func (m *MemoryCredStore) GetCredential(_ context.Context, subject string) (Credential, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.creds[subject]
	if !ok {
		return Credential{}, ErrCredNotFound
	}
	return c, nil
}

func (m *MemoryCredStore) IssueToken(_ context.Context, kind, subject, tokenHash, pwHash string, now, expires time.Time, floor MailFloor) (bool, error) {
	if kind == TokenVerify && pwHash == "" {
		return false, errors.New("auth: verification token needs a password hash")
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.creds[subject]; !ok {
		return false, ErrCredNotFound
	}
	var last time.Time
	today := 0
	for _, t := range m.tokens {
		if t.kind != kind || t.subject != subject {
			continue
		}
		if t.created.After(last) {
			last = t.created
		}
		if t.created.After(now.Add(-24 * time.Hour)) {
			today++
		}
	}
	if !last.IsZero() && now.Sub(last) < floor.MinInterval {
		return false, nil
	}
	if floor.MaxPerDay > 0 && today >= floor.MaxPerDay {
		return false, nil
	}
	if kind == TokenVerify {
		m.consumeAll(TokenVerify, subject) // only the newest link verifies (FR-015)
	}
	m.tokens[tokenHash] = &memToken{kind: kind, subject: subject, pwHash: pwHash, created: now, expires: expires}
	return true, nil
}

func (m *MemoryCredStore) consumeAll(kind, subject string) {
	for _, t := range m.tokens {
		if t.kind == kind && t.subject == subject {
			t.consumed = true
		}
	}
}

func (m *MemoryCredStore) ConsumeVerification(_ context.Context, tokenHash string, now time.Time, accept func(pwHash string) bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.tokens[tokenHash]
	if !ok || t.kind != TokenVerify {
		return ErrTokenInvalid
	}
	c := m.creds[t.subject]
	if c.Verified() {
		return nil
	}
	if t.consumed {
		return ErrTokenInvalid
	}
	if !t.expires.After(now) {
		return ErrTokenExpired
	}
	if !accept(t.pwHash) {
		return ErrVerifyPasswordMismatch
	}
	c.EmailVerifiedAt = &now
	c.PasswordHash = t.pwHash
	m.creds[t.subject] = c
	m.consumeAll(TokenVerify, t.subject)
	return nil
}

func (m *MemoryCredStore) ConsumeReset(_ context.Context, tokenHash, newHash string, now time.Time) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.tokens[tokenHash]
	if !ok || t.kind != TokenReset || t.consumed || !t.expires.After(now) {
		return "", ErrTokenInvalid
	}
	c := m.creds[t.subject]
	c.PasswordHash = newHash
	if c.EmailVerifiedAt == nil {
		c.EmailVerifiedAt = &now
	}
	m.creds[t.subject] = c
	m.consumeAll(TokenReset, t.subject)
	return t.subject, nil
}

func (m *MemoryCredStore) SetPassword(_ context.Context, subject, newHash string, _ time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.creds[subject]
	if !ok {
		return ErrCredNotFound
	}
	c.PasswordHash = newHash
	m.creds[subject] = c
	return nil
}

func (m *MemoryCredStore) TouchLogin(context.Context, string, time.Time) error { return nil }
