package hubclient

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/lockkey"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The box side of a locked box's hello (spec 025 box-owner-lock.md 4.4, row
// B9). A box sealed by the owner lock (lockkey.IsSealed) has K_box and K_lock
// only inside the sealed holder (lockd, row B4); this client never holds
// K_lock. Its role=box hello carries:
//
//   - boot_id, the kernel's boot id (a reboot needs the secret again, 4.3);
//   - the unlock ticket of an earlier welcome while it lives, else
//   - an unlock proof the holder signs with K_lock over
//     lockkey.ProofPayload(tenant, box, hello nonce, boot_id, box pubkey, ts).
//
// The first ticket a welcome carries is kept in memory only, and the holder
// is told to drop K_lock (4.4 step 3). A hello the hub refuses
// locked_box_sealed forgets the ticket, so the next one shows a proof. An
// unsealed box sends none of it: its hello is unchanged.

// helloLockedSealed is the hub's close reason for a locked box's hello with
// no valid proof or ticket (hub.helloLockedSealed).
const helloLockedSealed = "locked_box_sealed"

// bootIDPath is where Linux names the current boot.
var bootIDPath = "/proc/sys/kernel/random/boot_id"

// unlockState is a sealed box's unlock, per Client.
type unlockState struct {
	mu     sync.Mutex
	bootID string
	ticket string
}

// sealed reports whether box's key exists only in the sealed holder.
func (c *Client) sealed(box string) bool { return lockkey.IsSealed(c.Cfg.KeysDir, box) }

// bootID is this boot's id, read once; a host with no kernel boot id gets a
// random one for the life of this Client.
func (c *Client) bootID() string {
	u := &c.unlock
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.bootID != "" {
		return u.bootID
	}
	if b, err := os.ReadFile(bootIDPath); err == nil && strings.TrimSpace(string(b)) != "" {
		u.bootID = strings.TrimSpace(string(b))
		return u.bootID
	}
	r := make([]byte, 16)
	_, _ = rand.Read(r)
	u.bootID = hex.EncodeToString(r)
	return u.bootID
}

// addUnlock puts a sealed box's boot id and its ticket, or else the holder's
// proof, on a role=box hello. When the holder cannot sign (sealed again, or
// K_lock already dropped) the hello goes without one: the hub then refuses
// it locked_box_sealed and audits it (7.2), and the log names why.
func (c *Client) addUnlock(hello *wire.Frame) {
	hello.BootID = c.bootID()
	if t := c.liveTicket(); t != "" {
		hello.UnlockTicket = t
		return
	}
	sig, _, err := lockkey.HolderProof(c.Cfg.KeysDir, hello.Nonce, hello.BootID, hello.TS)
	if err != nil {
		c.Log.Warn().Err(err).Str("box", hello.BoxID).Msg("sealed box: no unlock proof for the hello")
		return
	}
	hello.UnlockProof = sig
}

// liveTicket is the kept ticket, or "" (and forgotten) once its own
// expires_at has passed: a stale ticket is only a refused hello.
func (c *Client) liveTicket() string {
	u := &c.unlock
	u.mu.Lock()
	defer u.mu.Unlock()
	if u.ticket == "" {
		return ""
	}
	if exp, ok := ticketExpiry(u.ticket); ok && !c.now().Before(exp) {
		u.ticket = ""
	}
	return u.ticket
}

// ticketExpiry reads expires_at from a ticket's body part. The signature is
// the hub's to check; a body this client cannot read is shown as is.
func ticketExpiry(t string) (time.Time, bool) {
	body, _, _ := strings.Cut(t, ".")
	raw, err := base64.RawURLEncoding.DecodeString(body)
	if err != nil {
		return time.Time{}, false
	}
	var v struct {
		ExpiresAt string `json:"expires_at"`
	}
	if json.Unmarshal(raw, &v) != nil {
		return time.Time{}, false
	}
	exp, err := time.Parse(time.RFC3339, v.ExpiresAt)
	return exp, err == nil
}

// keepTicket keeps the ticket a welcome carried and tells the holder to drop
// K_lock (4.4 step 3). Nothing for an unsealed box or a welcome with none.
func (c *Client) keepTicket(box, ticket string) {
	if ticket == "" || !c.sealed(box) {
		return
	}
	c.unlock.mu.Lock()
	c.unlock.ticket = ticket
	c.unlock.mu.Unlock()
	if err := lockkey.HolderDropLock(c.Cfg.KeysDir); err != nil {
		c.Log.Warn().Err(err).Str("box", box).Msg("sealed box: lockd did not drop the lock key")
		return
	}
	c.Log.Info().Str("box", box).Msg("sealed box: unlock ticket kept, lock key dropped")
}

// forgetTicket drops the kept ticket after a locked_box_sealed refusal.
func (c *Client) forgetTicket(err error) {
	var he *HubError
	if !errors.As(err, &he) || he.Token != helloLockedSealed {
		return
	}
	c.unlock.mu.Lock()
	c.unlock.ticket = ""
	c.unlock.mu.Unlock()
}
