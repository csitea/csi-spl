package action

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
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

// JoinEnvVar carries the join token, so it need not sit in argv (spec 073 4.4).
const JoinEnvVar = "SPOOL_JOIN_TOKEN"

// JoinArgs are the inputs of spool join (spec 073 4.4, spec 108 3.1). Token is
// the whole spj1.<tenant>.<secret>. HTTP and Now are test seams as in PinArgs.
type JoinArgs struct {
	HubURL, Token, Box string
	HTTP               *http.Client
	Now                func() time.Time
	// Timeout bounds the hub call; 0 = the hub client's REST default.
	Timeout time.Duration
}

// JoinResult is what a seated box learns: its tenant, box id and public key.
type JoinResult struct {
	Tenant, Box, PubKey string
}

// ReadJoinToken resolves the token: "-" reads stdin, "" reads $SPOOL_JOIN_TOKEN,
// anything else is the token itself. An error never echoes the value.
func ReadJoinToken(v string, stdin io.Reader) (string, error) {
	switch v {
	case "-":
		raw, err := io.ReadAll(io.LimitReader(stdin, 4<<10))
		if err != nil {
			return "", err
		}
		v = string(raw)
	case "":
		v = os.Getenv(JoinEnvVar)
	}
	v = strings.TrimSpace(v)
	if v == "" {
		return "", fmt.Errorf("no join token: set $%s or pass - to read it from stdin", JoinEnvVar)
	}
	return v, nil
}

// parseJoinToken splits spj1.<tenant>.<secret> into its tenant and the sha256
// hex of its secret, the only form of the secret that is ever signed.
func parseJoinToken(tok string) (tenant, hash string, ok bool) {
	parts := strings.Split(tok, ".")
	if len(parts) != 3 || parts[0] != "spj1" || !msg.ValidTenantID(parts[1]) || parts[2] == "" {
		return "", "", false
	}
	sum := sha256.Sum256([]byte(parts[2]))
	return parts[1], hex.EncodeToString(sum[:]), true
}

// Join seats this box with a join token: it uses the box key under KeysDir,
// generating one when none exists (as keygen), signs wire.JoinPayload with it
// and POSTs /v1/pins/join. Only the public half leaves the box; no private key
// is minted by, or received from, the hub (spec 108 3.1). On success the key
// is pinned in the local pin store too.
func Join(cfg *config.Config, in JoinArgs) (JoinResult, error) {
	if in.HubURL == "" || !msg.ValidBoxID(in.Box) {
		return JoinResult{}, fmt.Errorf("a hub url and --box (or $SPOOL_BOX_ID, a valid box id) are required")
	}
	tenant, hash, ok := parseJoinToken(in.Token)
	if !ok {
		return JoinResult{}, fmt.Errorf("the join token is malformed (want spj1.<tenant>.<secret>); ask a tenant admin for one in Tenant settings -> Agents")
	}
	priv, err := boxKey(cfg, in.Box)
	if err != nil {
		return JoinResult{}, err
	}
	pub := sign.PinForm(priv.Public().(ed25519.PublicKey))
	now := time.Now
	if in.Now != nil {
		now = in.Now
	}
	ts := now().UTC().Format(time.RFC3339)
	p, err := wire.JoinPayload(hash, in.Box, pub, ts)
	if err != nil {
		return JoinResult{}, fmt.Errorf("join payload: %w", err)
	}
	b, err := json.Marshal(wire.JoinRequest{Token: in.Token, BoxID: in.Box, PubKey: pub, TS: ts, Sig: sign.Sign(priv, p)})
	if err != nil {
		return JoinResult{}, err
	}
	if err := postJoin(cfg, in, tenant, b); err != nil {
		return JoinResult{}, err
	}
	if err := sign.Pin(cfg.PinsDir, in.Box, pub, false); err != nil {
		return JoinResult{}, fmt.Errorf("seated at the hub, but the local pin: %w", err)
	}
	return JoinResult{Tenant: tenant, Box: in.Box, PubKey: pub}, nil
}

// boxKey loads the box key, or generates it when the box has none.
func boxKey(cfg *config.Config, box string) (ed25519.PrivateKey, error) {
	if err := cfg.CheckKeysDir(); err != nil {
		return nil, err
	}
	priv, err := sign.LoadPrivate(cfg.KeysDir, box)
	if !errors.Is(err, sign.ErrUnpinned) {
		return priv, err
	}
	if _, err := sign.GenerateKey(cfg.KeysDir, box, false); err != nil {
		return nil, err
	}
	return sign.LoadPrivate(cfg.KeysDir, box)
}

// postJoin POSTs the signed body to /v1/pins/join, naming tenant; a refusal is
// a HubError carrying the hub's code and message (neither holds the token).
func postJoin(cfg *config.Config, in JoinArgs, tenant string, body []byte) error {
	hc := hubclient.New(cfg)
	if in.HTTP != nil {
		hc.HTTP = in.HTTP
	}
	hc.RESTTimeout = in.Timeout
	ctx, cancel := hc.RESTContext(context.Background())
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimSuffix(in.HubURL, "/")+"/v1/pins/join", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(hubclient.TenantHeader, tenant)
	resp, err := hc.HTTPClient().Do(req)
	if err != nil {
		return fmt.Errorf("%w: %w", hubclient.ErrUnreachable, err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<10))
	if resp.StatusCode >= 300 {
		var eb wire.ErrorBody
		json.Unmarshal(out, &eb) //nolint:errcheck
		if eb.Error == "" {
			eb.Error = http.StatusText(resp.StatusCode)
		}
		return &hubclient.HubError{Token: eb.Error, Status: resp.StatusCode, Detail: eb.Detail}
	}
	return nil
}
