package action

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// PinArgs are the inputs of spool-pin. RootKey is the tenant root private key
// (--root-key / $SPOOL_TENANT_ROOT_KEY) as ReadRootKey takes it. HTTP is an optional
// client (tests inject the in-process hub transport). Now is an optional clock
// for the signed ts (tests order two ops without sleeping); nil is time.Now.
type PinArgs struct {
	Box, PubKey, RootKey string
	Force, Revoke        bool
	HTTP                 *http.Client
	Now                  func() time.Time
	// Timeout bounds the hub call; 0 = the hub client's REST default.
	Timeout time.Duration
}

// Pin writes (or with Revoke removes) the local pin file and, when a tenant
// root key is provided, publishes that change to POST/DELETE /v1/pins.
func Pin(cfg *config.Config, in PinArgs) error {
	if !msg.ValidBoxID(in.Box) {
		return fmt.Errorf("--box (valid box id) is required")
	}
	if (in.PubKey == "") != in.Revoke {
		return fmt.Errorf("exactly one of --pubkey or --revoke is required")
	}
	if in.Revoke {
		if err := sign.Unpin(cfg.PinsDir, in.Box); err != nil {
			return err
		}
	} else if err := sign.Pin(cfg.PinsDir, in.Box, in.PubKey, in.Force); err != nil {
		return err
	}
	if in.RootKey == "" {
		return nil
	}
	if cfg.HubURL == "" {
		return fmt.Errorf("--root-key / $SPOOL_TENANT_ROOT_KEY needs hub mode ($SPOOL_HUB_URL)")
	}
	_, err := PublishPin(cfg, in)
	return err
}

// ReadRootKey resolves --root-key (specs/047 W17): "-" reads the key from
// stdin, an existing file is read, and anything else must be the base64 key
// text itself, pasted from wherever the tenant admin keeps it. An error never
// echoes the value, which may be the key.
func ReadRootKey(v string, stdin io.Reader) (ed25519.PrivateKey, error) {
	var raw []byte
	var err error
	src := "the --root-key text"
	switch {
	case v == "-":
		src = "the root key on stdin"
		raw, err = io.ReadAll(io.LimitReader(stdin, 4<<10))
	case fileExists(v):
		src = v
		raw, err = os.ReadFile(v)
	default:
		raw = []byte(v)
	}
	if err != nil {
		return nil, err
	}
	priv, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(raw)))
	if err != nil || len(priv) != ed25519.PrivateKeySize {
		return nil, rootKeyError(v, src)
	}
	return priv, nil
}

// rootKeyError says in plain words why --root-key was refused (spec 158 C):
// a value that names a file which is not there says the file does not
// exist, instead of calling the path a bad key. It never echoes v.
func rootKeyError(v, src string) error {
	if st, err := os.Stat(v); err == nil && st.IsDir() {
		return fmt.Errorf("the --root-key path is a directory, not the root key file")
	}
	if v != "-" && looksLikePath(v) && !fileExists(v) {
		return fmt.Errorf("the root key file does not exist: no file at the --root-key path. " +
			"Save the workspace root key there (mode 0600), or pass the key text, or - to read it from stdin")
	}
	return fmt.Errorf("%s is not a base64 ed25519 private key (nor a readable file)", src)
}

// looksLikePath is true for a value that is not the base64 key text: it
// starts like a path (an absolute one too: "/tmp/rootkey" holds only base64
// characters) or holds a character outside the base64 alphabet. A bad key
// text that starts with "/" then reads as a missing file; it is never echoed.
func looksLikePath(v string) bool {
	v = strings.TrimSpace(v)
	if strings.HasPrefix(v, "/") || strings.HasPrefix(v, "~") || strings.HasPrefix(v, "./") || strings.HasPrefix(v, "../") {
		return true
	}
	return strings.ContainsFunc(v, func(r rune) bool {
		return !(r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '+' || r == '/' || r == '=')
	})
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

// PublishPin POSTs or DELETEs /v1/pins signed by the tenant root key RootKey.
// It does not touch the local pin file (hub-pin). The private key is never sent.
func PublishPin(cfg *config.Config, in PinArgs) ([]byte, error) {
	if cfg.HubURL == "" || !msg.ValidBoxID(in.Box) || in.RootKey == "" || (in.PubKey == "") != in.Revoke {
		return nil, fmt.Errorf("$SPOOL_HUB_URL, --box, --root-key and exactly one of --pubkey / --revoke are required")
	}
	priv, err := ReadRootKey(in.RootKey, os.Stdin)
	if err != nil {
		return nil, err
	}
	now := time.Now
	if in.Now != nil {
		now = in.Now
	}
	// Sub-second ts: the hub requires each pin op to be later than the last one
	// (004 pin-semantics §5), so two ops in one second must still order.
	method, path, body, err := pinRequest(in, priv, now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		return nil, err
	}
	b, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	if bytes.Contains(bytes.ToLower(b), []byte(`"priv`)) || bytes.Contains(b, priv) {
		return nil, fmt.Errorf("pin JSON must not carry a private key")
	}
	hc := hubclient.New(cfg)
	if in.HTTP != nil {
		hc.HTTP = in.HTTP
	}
	hc.RESTTimeout = in.Timeout
	// r3-B02: the client has no Timeout; without this a hub that accepts and
	// never answers blocks spool pin for ever.
	ctx, cancel := hc.RESTContext(context.Background())
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimSuffix(cfg.HubURL, "/")+path, bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if t := cfg.TenantID(); t != "" { // specs/026: named, proven by the root signature
		req.Header.Set(hubclient.TenantHeader, t)
	}
	resp, err := hc.HTTPClient().Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", hubclient.ErrUnreachable, err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
	if resp.StatusCode >= 300 {
		var eb wire.ErrorBody
		json.Unmarshal(out, &eb) //nolint:errcheck
		return out, &hubclient.HubError{Token: eb.Error, Status: resp.StatusCode, Detail: eb.Detail}
	}
	return out, nil
}

// pinRequest is the signed pin (or revoke) body of PublishPin and its method
// and path. A payload that cannot be canonicalised is an error, never a
// signature over a nil payload.
func pinRequest(in PinArgs, priv ed25519.PrivateKey, ts string) (method, path string, body any, err error) {
	if in.Revoke {
		p, err := wire.RevokePayload(in.Box, ts)
		if err != nil {
			return "", "", nil, fmt.Errorf("revoke payload: %w", err)
		}
		return http.MethodDelete, "/v1/pins/" + in.Box, wire.RevokeRequest{BoxID: in.Box, TS: ts, Sig: sign.Sign(priv, p)}, nil
	}
	p, err := wire.PinPayload(in.Box, in.PubKey, ts, in.Force)
	if err != nil {
		return "", "", nil, fmt.Errorf("pin payload: %w", err)
	}
	return http.MethodPost, "/v1/pins", wire.PinRequest{BoxID: in.Box, PubKey: in.PubKey, TS: ts, Force: in.Force, Sig: sign.Sign(priv, p)}, nil
}
