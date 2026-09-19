package store

import (
	"context"
	"errors"
	"regexp"
	"time"
)

// A human's Ed25519 PUBLIC keys and their history (specs/023 T010/T011,
// contracts/keys-v1.md; rdb 0018_human_keys.sql). The hub never holds the
// private half. Hub-wide like humans: keyed by HUM-*, no tenant, no RLS.

// Human key sources and revoke reasons (human_keys.source / revoked_reason).
const (
	KeySourceGenerated = "generated"
	KeySourceUploaded  = "uploaded"
	KeyRevokedReplaced = "replaced"
	KeyRevokedByUser   = "revoked"
)

// HumanKey is one row. RevokedAt nil = the active key.
type HumanKey struct {
	ID            int64
	HumanID       string
	PublicKey     string // pin form: base64 of the 32 raw bytes
	Fingerprint   string // OpenSSH SHA256 form
	Source        string
	Label         string
	CreatedAt     time.Time
	RevokedAt     *time.Time
	RevokedReason string
}

// HumanKeys is the store side of keys-v1. Memory and Postgres implement it.
type HumanKeys interface {
	// AddHumanKey makes k the human's active key, revoking the previous
	// active one with reason replaced in the same transaction. A public key
	// registered before (any human, any state) is ErrConflict; an unknown
	// human is ErrNotFound. It returns the stored row.
	AddHumanKey(ctx context.Context, k HumanKey, now time.Time) (HumanKey, error)
	// HumanKeys lists the human's keys, newest first, history included.
	HumanKeys(ctx context.Context, humanID string) ([]HumanKey, error)
	// HumanKey returns one of the human's keys; another human's is ErrNotFound.
	HumanKey(ctx context.Context, humanID string, id int64) (HumanKey, error)
	// RevokeHumanKey revokes one of the human's keys with reason revoked.
	// Already revoked = the row unchanged; another human's = ErrNotFound.
	RevokeHumanKey(ctx context.Context, humanID string, id int64, now time.Time) (HumanKey, error)
}

var (
	pinFormRe     = regexp.MustCompile(`^[A-Za-z0-9+/]{43}=$`)
	fingerprintRe = regexp.MustCompile(`^SHA256:[A-Za-z0-9+/]{43}$`)
)

func checkHumanKey(k HumanKey) error {
	switch {
	case !pinFormRe.MatchString(k.PublicKey):
		return errors.New("human key: public_key must be base64 of 32 bytes")
	case !fingerprintRe.MatchString(k.Fingerprint):
		return errors.New("human key: fingerprint must be SHA256:<base64>")
	case k.Source != KeySourceGenerated && k.Source != KeySourceUploaded:
		return errors.New("human key: source must be generated or uploaded")
	case len(k.Label) > 80:
		return errors.New("human key: label is at most 80 bytes")
	case k.HumanID == "":
		return errors.New("human key: human_id is required")
	}
	return nil
}

var (
	_ HumanKeys = (*Memory)(nil)
	_ HumanKeys = (*Postgres)(nil)
)
