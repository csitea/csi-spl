package keydesk

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"filippo.io/age"
)

// Payload is the plaintext of the hub's sealed lease answer (127 5.2 step
// 3). The hub seals it to the desk's X25519 recipient with age, so a
// TLS-terminating proxy sees ciphertext only. Kind and Box bind the answer:
// the desk refuses one that names another kind or another box. This is the
// contract the hub's lease route (127 H2) seals to; Seal is its reference.
type Payload struct {
	Kind       string `json:"kind"`
	Box        string `json:"box"`
	KeyID      string `json:"key_id"`
	Key        string `json:"key"`
	BaseURL    string `json:"base_url,omitempty"` // qwen only
	TTLSeconds int    `json:"ttl_s,omitempty"`    // the hub's lease TTL; the desk keeps the shorter
}

// String never prints the key.
func (p Payload) String() string {
	return fmt.Sprintf("{kind:%s box:%s key_id:%s key:<VENDOR_KEY>}", p.Kind, p.Box, p.KeyID)
}

// maxSealed caps a sealed answer: an agy service-account JSON is the largest.
const maxSealed = 64 << 10

// Seal encrypts p to the desk's recipient (the hub's half, and the tests').
func Seal(to age.Recipient, p Payload) ([]byte, error) {
	plain, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	var out bytes.Buffer
	w, err := age.Encrypt(&out, to)
	if err != nil {
		return nil, err
	}
	if _, err := w.Write(plain); err != nil {
		return nil, err
	}
	if err := w.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// Open decrypts a sealed answer with the desk's identity, in memory only.
func Open(id age.Identity, sealed []byte) (Payload, error) {
	if len(sealed) == 0 || len(sealed) > maxSealed {
		return Payload{}, errors.New("keydesk: sealed lease empty or too large")
	}
	r, err := age.Decrypt(bytes.NewReader(sealed), id)
	if err != nil {
		return Payload{}, errors.New("keydesk: the sealed lease does not open with this desk's key")
	}
	plain, err := io.ReadAll(io.LimitReader(r, maxSealed))
	if err != nil {
		return Payload{}, errors.New("keydesk: the sealed lease is cut short")
	}
	var p Payload
	dec := json.NewDecoder(bytes.NewReader(plain))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&p); err != nil {
		return Payload{}, errors.New("keydesk: the sealed lease is not a lease payload")
	}
	return p, nil
}

// IdentityName is the desk's X25519 identity file in its box root's hub
// dir: the sidecar's desk opens leases with it, and `spool join` sends its
// recipient (spec 127 5.2 step 3), so both derive the one path.
const IdentityName = "desk-x25519.key"

// IdentityPath is the identity file of the box root whose hub dir is hubDir.
func IdentityPath(hubDir string) string { return filepath.Join(hubDir, IdentityName) }

// LoadOrCreateIdentity reads the desk's X25519 identity from path, or makes
// one there (0600, O_EXCL) on the first start. It returns the identity and
// its public recipient (`age1...`), which the box registers at join (127
// 5.2 step 3, the join field is 127 H2's).
func LoadOrCreateIdentity(path string) (*age.X25519Identity, error) {
	b, err := os.ReadFile(path) // #nosec G304 -- the desk's own state file
	if err == nil {
		st, serr := os.Stat(path)
		if serr != nil || st.Mode().Perm()&0o077 != 0 {
			return nil, fmt.Errorf("keydesk: %s must be mode 0600", path)
		}
		return age.ParseX25519Identity(strings.TrimSpace(string(b)))
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	id, err := age.GenerateX25519Identity()
	if err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600) // #nosec G304 -- see above
	if err != nil {
		return nil, err
	}
	if _, err := f.WriteString(id.String() + "\n"); err != nil {
		f.Close() //nolint:errcheck
		return nil, err
	}
	return id, f.Close()
}
