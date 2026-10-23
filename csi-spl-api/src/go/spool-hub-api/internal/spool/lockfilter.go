package spool

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"

	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// The owner box's own check (spec 025 box-owner-lock.md section 5.3, row
// B7, SPL-2992): defence in depth behind the hub's queue points (B3). The
// sidecar of a sealed box keeps its lock's owners and peer_boxes, verified
// with K_lock's public half, and drops a delivery whose from_box is not
// itself, box-wui or a peer box, or, from box-wui, whose human (the post's
// from, a HUM-*) is not an owner. A hub frame never carries typed_by
// (wire.Frame.TypedBy), so the human a box can check is a browser post's
// from: the same rule as the hub's lockAdmits. It catches a hub that lost
// its check; it does not catch a hub that lies (8.2).
//
// The lock is the owner's signed statement, `spool lock create` (or
// `rebind`) output as printed, saved as lock/lock.signed.json under the
// box's keys dir. A box with no lock/lock.json is not sealed: nothing is
// filtered. A sealed box whose signed lock is missing, malformed, signed by
// another key or for another box is locked to nobody (fail closed, like a
// tampered row, 6.1): only its own box's mail is delivered.

// signedLockFile is the owner's signed lock statement under lock/.
const signedLockFile = "lock.signed.json"

// wuiFromBox is the hub-held browser signer (specs/014): its posts are a
// member's, from the poster's HUM-*.
const wuiFromBox = "box-wui"

// boxLockFilter is what the sidecar knows of its own lock. A tampered lock
// has no owner and no peer.
type boxLockFilter struct {
	box      string
	owners   []string
	peers    []string
	tampered string // why the lock admits nobody, "" when it verified
}

// signedLockStatement is the part of `spool lock create`'s output read here.
type signedLockStatement struct {
	SignedBody string `json:"signed_body"`
	Signature  string `json:"signature"`
}

// loadBoxLockFilter is nil for a box that is not sealed, else the verified
// lock (or a tampered one that admits only the box itself).
func loadBoxLockFilter(keysDir string) *boxLockFilter {
	if keysDir == "" {
		return nil
	}
	meta, err := lockkey.ReadMeta(keysDir)
	if errors.Is(err, lockkey.ErrNotSealed) {
		return nil
	}
	if err != nil {
		return &boxLockFilter{tampered: err.Error()}
	}
	f := &boxLockFilter{box: meta.Box}
	body, err := readSignedLock(keysDir, meta)
	if err != nil {
		f.tampered = err.Error()
		return f
	}
	f.owners, f.peers = body.Owners, body.PeerBoxes
	return f
}

// readSignedLock reads lock/lock.signed.json and verifies it: K_lock's
// signature over signed_body, the body in its canonical form, and the
// tenant, box and lock key of lock.json.
func readSignedLock(keysDir string, meta lockkey.Meta) (lockkey.Body, error) {
	var b lockkey.Body
	raw, err := os.ReadFile(filepath.Join(lockkey.LockDir(keysDir), signedLockFile))
	if err != nil {
		return b, fmt.Errorf("no signed lock (%s): %w", signedLockFile, err)
	}
	var st signedLockStatement
	if err := json.Unmarshal(raw, &st); err != nil {
		return b, fmt.Errorf("%s is malformed", signedLockFile)
	}
	pub, err := base64.StdEncoding.DecodeString(meta.LockPubkey)
	if err != nil || len(pub) != ed25519.PublicKeySize {
		return b, errors.New("lock.json lock_pubkey is not a base64 Ed25519 key")
	}
	sig, err := base64.StdEncoding.DecodeString(st.Signature)
	if err != nil || !ed25519.Verify(ed25519.PublicKey(pub), []byte(st.SignedBody), sig) {
		return b, fmt.Errorf("%s: the signature does not hold under lock.json's lock key", signedLockFile)
	}
	if err := json.Unmarshal([]byte(st.SignedBody), &b); err != nil {
		return b, fmt.Errorf("%s: signed_body is malformed", signedLockFile)
	}
	if c, err := b.Canonical(); err != nil || string(c) != st.SignedBody {
		return b, fmt.Errorf("%s: signed_body is not in canonical form", signedLockFile)
	}
	if b.TenantID != meta.Tenant || b.BoxID != meta.Box || b.LockPubkey != meta.LockPubkey {
		return b, fmt.Errorf("%s is a lock of another box or key", signedLockFile)
	}
	return b, nil
}

// admits reports whether a message from fromBox, sent by from, may be
// delivered on this box. fromBox "" is this box: a local delivery.
func (f *boxLockFilter) admits(fromBox, from string) bool {
	if fromBox == "" || (f.box != "" && fromBox == f.box) {
		return true
	}
	if f.tampered != "" {
		return false
	}
	if fromBox == wuiFromBox {
		return from != "" && slices.Contains(f.owners, from)
	}
	return slices.Contains(f.peers, fromBox)
}

// lockDrops is deliverTo's check: true = do not write m into id's inbox.
// A drop is logged (ids and boxes only, never the body).
func (s *Store) lockDrops(m *msg.Message, id string) bool {
	f := loadBoxLockFilter(s.cfg.KeysDir)
	if f == nil || f.admits(s.fromBox, m.From) {
		return false
	}
	why := "not an owner or a peer box"
	if f.tampered != "" {
		why = "lock admits nobody: " + f.tampered
	}
	fmt.Fprintf(s.warnOut(), "spool: box lock dropped msg %s to %s from %s (from_box %s): %s\n",
		m.MsgID, id, m.From, s.fromBox, why)
	return true
}

// FromBox is s for deliveries the hub brought from box: the sidecar names
// the envelope's from_box so the box lock filter can judge it. A Store
// without it delivers as this box (a local send).
func (s *Store) FromBox(box string) *Store {
	c := *s
	c.fromBox = box
	return &c
}
