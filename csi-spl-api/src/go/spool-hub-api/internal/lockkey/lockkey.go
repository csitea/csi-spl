// Package lockkey is the box side of the box owner lock (spec 025
// box-owner-lock.md sections 4 and 6.1, row B4): the lock key K_lock and the
// box key K_box sealed at rest under the owner's lock secret, the recovery
// code, the unlock proof a locked box signs for its hello, and the canonical
// lock body K_lock signs.
//
// Sealing (4.2): KEK = argon2id(secret, salt, t=3, m=256 MiB, p=4, 32 bytes);
// a sub-key per key kind by HKDF-SHA256 over KEK; the seed sealed with
// XChaCha20-Poly1305 under a random 24-byte nonce and the associated data
// tenant|box|kind|version, so a file moved to another box, or swapped between
// kinds, does not open. The header (version, KDF parameters, salt, nonce) is
// clear; the secret and KEK are never written.
package lockkey

import (
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/chacha20poly1305"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// FormatVersion is the sealed file format, bound into the associated data.
const FormatVersion = 1

// Key kinds. Each is bound into the associated data of its file.
const (
	KindLock         = "lock"          // K_lock under the lock secret
	KindLockRecovery = "lock-recovery" // K_lock under the recovery code
	KindBox          = "box"           // K_box under the lock secret
)

// MinSecret is the shortest lock secret seal accepts (4.2 step 1).
const MinSecret = 16

// ErrOpen is every failed open: wrong secret, a file sealed for another box,
// tenant or kind, or a changed byte. It never says which, nor the secret.
var ErrOpen = errors.New("the sealed key did not open: wrong secret, or a file sealed for another box or kind")

// Params are the argon2id cost parameters, stored in each file's header.
type Params struct {
	Time    uint32
	MemKiB  uint32
	Threads uint8
}

// DefaultParams is 4.2 step 2: t=3, m=256 MiB, p=4.
var DefaultParams = Params{Time: 3, MemKiB: 256 * 1024, Threads: 4}

// maxMemKiB caps what a header may ask Open to allocate (1 GiB).
const maxMemKiB = 1024 * 1024

// file is the on-disk form: JSON, every field but ct readable.
type file struct {
	V      int    `json:"v"`
	KDF    string `json:"kdf"`
	T      uint32 `json:"t"`
	MemKiB uint32 `json:"m_kib"`
	P      uint8  `json:"p"`
	Salt   string `json:"salt"`
	Nonce  string `json:"nonce"`
	Kind   string `json:"kind"`
	CT     string `json:"ct"`
}

func subInfo(kind string) (string, error) {
	switch kind {
	case KindLock, KindLockRecovery:
		return "spool-lock-key", nil
	case KindBox:
		return "spool-box-key", nil
	}
	return "", fmt.Errorf("unknown key kind %q", kind)
}

// AssociatedData is tenant|box|kind|format-version (4.2 step 4).
func AssociatedData(tenant, box, kind string) []byte {
	return fmt.Appendf(nil, "%s|%s|%s|%d", tenant, box, kind, FormatVersion)
}

// aad is the binding Seal and Open use. Only the red control replaces it.
var aad = AssociatedData

func checkIDs(tenant, box string) error {
	if !msg.ValidTenantID(tenant) {
		return fmt.Errorf("tenant %q is not a tenant id", tenant)
	}
	if !msg.ValidBoxID(box) {
		return fmt.Errorf("box %q is not a box id", box)
	}
	return nil
}

func deriveKEK(secret, salt []byte, p Params) []byte {
	return argon2.IDKey(secret, salt, p.Time, p.MemKiB, p.Threads, 32)
}

func subKey(kek []byte, kind string) ([]byte, error) {
	info, err := subInfo(kind)
	if err != nil {
		return nil, err
	}
	return hkdf.Key(sha256.New, kek, nil, info, chacha20poly1305.KeySize)
}

// Sealer seals several files under one KEK (one argon2id run, one salt).
type Sealer struct {
	kek  []byte
	salt []byte
	p    Params
}

// NewSealer derives a KEK from secret with a fresh random salt. An empty
// secret is refused; the length rule is the caller's (a recovery code is raw
// bytes, a typed secret has MinSecret).
func NewSealer(secret []byte, p Params) (*Sealer, error) {
	if len(secret) == 0 {
		return nil, errors.New("an empty secret is refused")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return nil, err
	}
	return &Sealer{kek: deriveKEK(secret, salt, p), salt: salt, p: p}, nil
}

// Seal returns the sealed file of plain, bound to tenant, box and kind.
func (s *Sealer) Seal(tenant, box, kind string, plain []byte) ([]byte, error) {
	if err := checkIDs(tenant, box); err != nil {
		return nil, err
	}
	key, err := subKey(s.kek, kind)
	if err != nil {
		return nil, err
	}
	defer Wipe(key)
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	ct := aead.Seal(nil, nonce, plain, aad(tenant, box, kind))
	b, err := json.Marshal(file{V: FormatVersion, KDF: "argon2id", T: s.p.Time, MemKiB: s.p.MemKiB, P: s.p.Threads,
		Salt: b64(s.salt), Nonce: b64(nonce), Kind: kind, CT: b64(ct)})
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// Wipe zeroes the KEK.
func (s *Sealer) Wipe() { Wipe(s.kek) }

// Opener opens files under one secret, deriving each salt's KEK once.
type Opener struct {
	secret []byte
	keks   map[string][]byte
}

// NewOpener keeps a copy of secret until Wipe.
func NewOpener(secret []byte) *Opener {
	return &Opener{secret: append([]byte(nil), secret...), keks: map[string][]byte{}}
}

// Open returns the plain seed of a file sealed for tenant, box and kind.
func (o *Opener) Open(tenant, box, kind string, raw []byte) ([]byte, error) {
	if err := checkIDs(tenant, box); err != nil {
		return nil, err
	}
	var f file
	if err := json.Unmarshal(raw, &f); err != nil || f.V != FormatVersion || f.KDF != "argon2id" {
		return nil, errors.New("the sealed key file is not a v1 argon2id file")
	}
	if f.T == 0 || f.T > 16 || f.P == 0 || f.P > 16 || f.MemKiB < 8 || f.MemKiB > maxMemKiB {
		return nil, errors.New("the sealed key file asks for KDF parameters out of range")
	}
	salt, err1 := unb64(f.Salt)
	nonce, err2 := unb64(f.Nonce)
	ct, err3 := unb64(f.CT)
	if err1 != nil || err2 != nil || err3 != nil || len(salt) < 16 || len(nonce) != chacha20poly1305.NonceSizeX {
		return nil, errors.New("the sealed key file is malformed")
	}
	p := Params{Time: f.T, MemKiB: f.MemKiB, Threads: f.P}
	ck := fmt.Sprintf("%x|%d|%d|%d", salt, p.Time, p.MemKiB, p.Threads)
	kek, ok := o.keks[ck]
	if !ok {
		kek = deriveKEK(o.secret, salt, p)
		o.keks[ck] = kek
	}
	key, err := subKey(kek, kind)
	if err != nil {
		return nil, err
	}
	defer Wipe(key)
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	plain, err := aead.Open(nil, nonce, ct, aad(tenant, box, kind))
	if err != nil {
		return nil, ErrOpen
	}
	return plain, nil
}

// Wipe zeroes the secret copy and every derived KEK.
func (o *Opener) Wipe() {
	Wipe(o.secret)
	for k, v := range o.keks {
		Wipe(v)
		delete(o.keks, k)
	}
}

// Open is a one-file Opener.
func Open(secret []byte, tenant, box, kind string, raw []byte) ([]byte, error) {
	o := NewOpener(secret)
	defer o.Wipe()
	return o.Open(tenant, box, kind, raw)
}

// ---- recovery code (4.5) -------------------------------------------------------

var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

// NewRecoveryCode returns 256 random bits as base32 in dash-separated groups
// of 4 characters (13 groups, the last one 4), and the raw bytes that are the
// recovery secret.
func NewRecoveryCode() (code string, raw []byte, err error) {
	raw = make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", nil, err
	}
	s := b32.EncodeToString(raw)
	var g []string
	for i := 0; i < len(s); i += 4 {
		g = append(g, s[i:min(i+4, len(s))])
	}
	return strings.Join(g, "-"), raw, nil
}

// ParseRecoveryCode accepts the code with or without dashes or spaces, any case.
func ParseRecoveryCode(code string) ([]byte, error) {
	c := strings.ToUpper(strings.NewReplacer("-", "", " ", "", "\n", "", "\r", "", "\t", "").Replace(code))
	raw, err := b32.DecodeString(c)
	if err != nil || len(raw) != 32 {
		return nil, errors.New("the recovery code is not a 256-bit base32 code")
	}
	return raw, nil
}

// ---- unlock proof (4.4) and lock body (6.1) --------------------------------------

// ProofPayload is the byte string K_lock signs in a locked box's hello:
// "spool-unlock-v1" | tenant | box | hub_nonce | boot_id | K_box public key | ts.
func ProofPayload(tenant, box, hubNonce, bootID, boxPub, ts string) []byte {
	return []byte(strings.Join([]string{"spool-unlock-v1", tenant, box, hubNonce, bootID, boxPub, ts}, "|"))
}

// Body is the lock row K_lock signs. Field order and tags are the hub's
// canonical form (row B1, store.BoxLockBody): encoding/json, in this order,
// an empty list as [], keys as standard base64.
type Body struct {
	TenantID   string   `json:"tenant_id"`
	BoxID      string   `json:"box_id"`
	LockPubkey string   `json:"lock_pubkey"`
	BoxPubkey  string   `json:"box_pubkey"`
	Owners     []string `json:"owners"`
	PeerBoxes  []string `json:"peer_boxes"`
	HidePosts  bool     `json:"hide_posts"`
	Version    int64    `json:"version"`
}

// Canonical is the exact byte string signed and stored as signed_body.
func (b Body) Canonical() ([]byte, error) {
	if b.Owners == nil {
		b.Owners = []string{}
	}
	if b.PeerBoxes == nil {
		b.PeerBoxes = []string{}
	}
	return json.Marshal(b)
}

// PubB64 is the standard base64 of an Ed25519 public key.
func PubB64(pub ed25519.PublicKey) string { return b64(pub) }

// SignB64 signs payload with priv and returns the standard base64 signature.
func SignB64(priv ed25519.PrivateKey, payload []byte) string { return b64(ed25519.Sign(priv, payload)) }

// Wipe zeroes a secret buffer.
func Wipe(b []byte) {
	for i := range b {
		b[i] = 0
	}
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }

func unb64(s string) ([]byte, error) { return base64.StdEncoding.DecodeString(s) }
