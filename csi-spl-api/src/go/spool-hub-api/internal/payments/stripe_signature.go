package payments

// Copied from csi-rel csi-rel-api/src/internal/webhooks/signature.go (Stripe
// part, tree e4612828). Stripe-Signature: t=<unix>,v1=<hex>[,v0=<hex>].

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"
)

// stripeTolerance is the replay-protection window. 5 minutes matches the
// Stripe-recommended default. Reject events whose timestamp is older.
const stripeTolerance = 5 * time.Minute

// VerifyStripe checks the Stripe-Signature header against body using secret.
// Returns nil on success, ErrSigBad otherwise (timestamp drift, missing
// v1, hex parse failure, or HMAC mismatch all collapse to the same error).
func VerifyStripe(header, body, secret string, now time.Time) error {
	if secret == "" || header == "" {
		return ErrSigBad
	}
	var (
		tsRaw string
		sigs  []string
	)
	for _, part := range strings.Split(header, ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			continue
		}
		switch k {
		case "t":
			tsRaw = v
		case "v1":
			sigs = append(sigs, v)
		}
	}
	if tsRaw == "" || len(sigs) == 0 {
		return ErrSigBad
	}

	ts, err := strconv.ParseInt(tsRaw, 10, 64)
	if err != nil {
		return ErrSigBad
	}
	if d := now.Sub(time.Unix(ts, 0)); d > stripeTolerance || d < -stripeTolerance {
		return ErrSigBad
	}

	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(tsRaw))
	mac.Write([]byte("."))
	mac.Write([]byte(body))
	want := hex.EncodeToString(mac.Sum(nil))

	for _, s := range sigs {
		if hmac.Equal([]byte(s), []byte(want)) {
			return nil
		}
	}
	return ErrSigBad
}

// SignStripe is the inverse — used by tests (and the lde stripe-mock) to mint
// valid signature headers. Production code never calls it; it lives next to
// VerifyStripe so drift between sign and verify is mechanically impossible.
func SignStripe(body, secret string, ts time.Time) string {
	tsRaw := strconv.FormatInt(ts.Unix(), 10)
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(tsRaw))
	mac.Write([]byte("."))
	mac.Write([]byte(body))
	return "t=" + tsRaw + ",v1=" + hex.EncodeToString(mac.Sum(nil))
}
