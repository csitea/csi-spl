package lockkey

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// The files of a sealed box, under the box's keys dir (4.1):
//
//	box-<id>.key.enc               K_box under the lock secret (the clear box-<id>.key is gone)
//	lock/lock.key.enc              K_lock under the lock secret
//	lock/lock.key.recovery.enc     K_lock under the recovery code
//	lock/lock.json                 public: tenant, box, lock and box public keys
//	lock/lockd.sock, lockd.pid     the sealed holder (daemon.go)
const (
	lockDirName  = "lock"
	lockFile     = "lock.key.enc"
	recoveryFile = "lock.key.recovery.enc"
	metaFile     = "lock.json"
)

// ErrNotSealed means this box has no sealed lock files.
var ErrNotSealed = errors.New("this box is not sealed (no lock files)")

// ErrSealed means the box key exists only sealed and no holder has it open.
var ErrSealed = errors.New("the box key is sealed: the owner runs 'spool lock unlock' on this box")

// Meta is lock.json: nothing secret.
type Meta struct {
	V          int    `json:"v"`
	Tenant     string `json:"tenant_id"`
	Box        string `json:"box_id"`
	LockPubkey string `json:"lock_pubkey"`
	BoxPubkey  string `json:"box_pubkey"`
}

// Keys are both private keys of an unlocked box.
type Keys struct {
	Meta Meta
	Lock ed25519.PrivateKey // nil once dropped (4.4 step 3), or when opened by recovery without it
	Box  ed25519.PrivateKey
}

// Wipe zeroes both private keys.
func (k *Keys) Wipe() {
	Wipe(k.Lock)
	Wipe(k.Box)
	k.Lock, k.Box = nil, nil
}

// LockDir is <keysDir>/lock.
func LockDir(keysDir string) string { return filepath.Join(keysDir, lockDirName) }

// SealedBoxPath is <keysDir>/box-<id>.key.enc.
func SealedBoxPath(keysDir, box string) string {
	return filepath.Join(keysDir, "box-"+box+".key.enc")
}

func clearBoxPath(keysDir, box string) string { return filepath.Join(keysDir, "box-"+box+".key") }

// IsSealed reports whether box's key exists sealed under keysDir.
func IsSealed(keysDir, box string) bool {
	_, err := os.Stat(SealedBoxPath(keysDir, box))
	return err == nil
}

// ReadMeta reads lock.json.
func ReadMeta(keysDir string) (Meta, error) {
	raw, err := os.ReadFile(filepath.Join(LockDir(keysDir), metaFile))
	if errors.Is(err, os.ErrNotExist) {
		return Meta{}, ErrNotSealed
	}
	if err != nil {
		return Meta{}, err
	}
	var m Meta
	if err := json.Unmarshal(raw, &m); err != nil || m.V != 1 || checkIDs(m.Tenant, m.Box) != nil {
		return Meta{}, errors.New("lock.json is malformed")
	}
	return m, nil
}

// SealResult is what Seal reports: the public meta and the recovery code,
// shown once and never stored.
type SealResult struct {
	Meta         Meta
	RecoveryCode string
}

// Seal locks box at rest (4.2): a new K_lock; K_box is the box's clear key
// (made when the box has none); both sealed under secret, K_lock also under a
// new recovery code; then the clear box key is overwritten and removed.
// A box already sealed is refused (use Reseal).
func Seal(keysDir, tenant, box string, secret []byte, p Params) (SealResult, error) {
	if err := checkIDs(tenant, box); err != nil {
		return SealResult{}, err
	}
	if len([]rune(string(secret))) < MinSecret {
		return SealResult{}, fmt.Errorf("the lock secret needs at least %d characters", MinSecret)
	}
	if IsSealed(keysDir, box) {
		return SealResult{}, errors.New("this box is already sealed (use spool lock reseal)")
	}
	if _, err := os.Stat(filepath.Join(LockDir(keysDir), lockFile)); err == nil {
		return SealResult{}, errors.New("a lock key already exists on this box (use spool lock reseal)")
	}
	boxPriv, err := loadOrNewClearBox(keysDir, box)
	if err != nil {
		return SealResult{}, err
	}
	defer Wipe(boxPriv)
	_, lockPriv, err := ed25519.GenerateKey(nil)
	if err != nil {
		return SealResult{}, err
	}
	defer Wipe(lockPriv)
	code, rec, err := NewRecoveryCode()
	if err != nil {
		return SealResult{}, err
	}
	defer Wipe(rec)
	k := Keys{Meta: Meta{V: 1, Tenant: tenant, Box: box,
		LockPubkey: PubB64(lockPriv.Public().(ed25519.PublicKey)),
		BoxPubkey:  PubB64(boxPriv.Public().(ed25519.PublicKey))}, Lock: lockPriv, Box: boxPriv}
	if err := writeSealed(keysDir, k, secret, p); err != nil {
		return SealResult{}, err
	}
	if err := writeRecovery(keysDir, k, rec, p); err != nil {
		return SealResult{}, err
	}
	if err := writeMeta(keysDir, k.Meta); err != nil {
		return SealResult{}, err
	}
	if err := shred(clearBoxPath(keysDir, box)); err != nil {
		return SealResult{}, fmt.Errorf("sealed, but the clear box key was not removed: %w", err)
	}
	return SealResult{Meta: k.Meta, RecoveryCode: code}, nil
}

// Unseal opens both keys with the lock secret.
func Unseal(keysDir string, secret []byte) (Keys, error) {
	m, err := ReadMeta(keysDir)
	if err != nil {
		return Keys{}, err
	}
	o := NewOpener(secret)
	defer o.Wipe()
	lock, err := openKey(o, m, KindLock, filepath.Join(LockDir(keysDir), lockFile), m.LockPubkey)
	if err != nil {
		return Keys{}, err
	}
	bx, err := openKey(o, m, KindBox, SealedBoxPath(keysDir, m.Box), m.BoxPubkey)
	if err != nil {
		Wipe(lock)
		return Keys{}, err
	}
	return Keys{Meta: m, Lock: lock, Box: bx}, nil
}

// OpenLockByRecovery opens K_lock with the recovery code (4.5).
func OpenLockByRecovery(keysDir string, recovery []byte) (Meta, ed25519.PrivateKey, error) {
	m, err := ReadMeta(keysDir)
	if err != nil {
		return Meta{}, nil, err
	}
	o := NewOpener(recovery)
	defer o.Wipe()
	lock, err := openKey(o, m, KindLockRecovery, filepath.Join(LockDir(keysDir), recoveryFile), m.LockPubkey)
	return m, lock, err
}

// Reseal writes both sealed files under newSecret. k.Box nil means the old
// K_box is not recoverable (recovery-code reseal): a new K_box is made, and
// the returned meta carries its public key, which the hub accepts only
// after a rebind (6.2).
func Reseal(keysDir string, k Keys, newSecret []byte, p Params) (Meta, error) {
	if len([]rune(string(newSecret))) < MinSecret {
		return Meta{}, fmt.Errorf("the lock secret needs at least %d characters", MinSecret)
	}
	if k.Lock == nil {
		return Meta{}, errors.New("reseal needs the lock key")
	}
	if k.Box == nil {
		_, nb, err := ed25519.GenerateKey(nil)
		if err != nil {
			return Meta{}, err
		}
		k.Box = nb
		defer Wipe(nb)
		k.Meta.BoxPubkey = PubB64(nb.Public().(ed25519.PublicKey))
	}
	if err := writeSealed(keysDir, k, newSecret, p); err != nil {
		return Meta{}, err
	}
	return k.Meta, writeMeta(keysDir, k.Meta)
}

// RotateRecovery replaces the recovery copy of K_lock with one under a new
// code; the old code stops opening anything.
func RotateRecovery(keysDir string, k Keys, p Params) (string, error) {
	if k.Lock == nil {
		return "", errors.New("rotate-recovery needs the lock key")
	}
	code, rec, err := NewRecoveryCode()
	if err != nil {
		return "", err
	}
	defer Wipe(rec)
	return code, writeRecovery(keysDir, k, rec, p)
}

func openKey(o *Opener, m Meta, kind, path, wantPub string) (ed25519.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", filepath.Base(path), err)
	}
	seed, err := o.Open(m.Tenant, m.Box, kind, raw)
	if err != nil {
		return nil, err
	}
	defer Wipe(seed)
	if len(seed) != ed25519.SeedSize {
		return nil, ErrOpen
	}
	priv := ed25519.NewKeyFromSeed(seed)
	if PubB64(priv.Public().(ed25519.PublicKey)) != wantPub {
		Wipe(priv)
		return nil, errors.New("the opened key does not match lock.json")
	}
	return priv, nil
}

func writeSealed(keysDir string, k Keys, secret []byte, p Params) error {
	s, err := NewSealer(secret, p)
	if err != nil {
		return err
	}
	defer s.Wipe()
	lf, err := s.Seal(k.Meta.Tenant, k.Meta.Box, KindLock, k.Lock.Seed())
	if err != nil {
		return err
	}
	bf, err := s.Seal(k.Meta.Tenant, k.Meta.Box, KindBox, k.Box.Seed())
	if err != nil {
		return err
	}
	if err := writeFile(filepath.Join(LockDir(keysDir), lockFile), lf); err != nil {
		return err
	}
	return writeFile(SealedBoxPath(keysDir, k.Meta.Box), bf)
}

func writeRecovery(keysDir string, k Keys, rec []byte, p Params) error {
	s, err := NewSealer(rec, p)
	if err != nil {
		return err
	}
	defer s.Wipe()
	rf, err := s.Seal(k.Meta.Tenant, k.Meta.Box, KindLockRecovery, k.Lock.Seed())
	if err != nil {
		return err
	}
	return writeFile(filepath.Join(LockDir(keysDir), recoveryFile), rf)
}

func writeMeta(keysDir string, m Meta) error {
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return writeFile(filepath.Join(LockDir(keysDir), metaFile), append(b, '\n'))
}

// writeFile writes 0600 through a temp file and a rename, so a crash never
// leaves half a sealed key.
func writeFile(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	if err := f.Close(); err != nil {
		os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, path)
}

// loadOrNewClearBox reads the clear box-<id>.key (sign package format, the
// base64 of the 64-byte key), or makes a new key when there is none.
func loadOrNewClearBox(keysDir, box string) (ed25519.PrivateKey, error) {
	raw, err := os.ReadFile(clearBoxPath(keysDir, box))
	if errors.Is(err, os.ErrNotExist) {
		_, priv, gerr := ed25519.GenerateKey(nil)
		return priv, gerr
	}
	if err != nil {
		return nil, err
	}
	defer Wipe(raw)
	dec, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(dec) != ed25519.PrivateKeySize {
		return nil, fmt.Errorf("the clear box key of %s is malformed", box)
	}
	return ed25519.PrivateKey(dec), nil
}

// shred overwrites path with zeros, syncs, and removes it. Missing is fine.
func shred(path string) error {
	st, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	if _, err := f.Write(make([]byte, st.Size())); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	f.Close()
	return os.Remove(path)
}
