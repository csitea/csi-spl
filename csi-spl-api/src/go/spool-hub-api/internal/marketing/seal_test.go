package marketing

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"
)

// testSecret is a made-up value: tests only ever run against FakeKMS.
const (
	testSecret  = "fake-oauth-token-not-a-secret-0123"
	testKeyName = "projects/p/locations/l/keyRings/r/cryptoKeys/marketing"
)

func newTestSealer(t *testing.T) *Sealer {
	t.Helper()
	s, err := NewSealer(NewFakeKMS(), testKeyName)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestSealOpenRoundTrip(t *testing.T) {
	ctx := context.Background()
	s := newTestSealer(t)
	ct, keyID, err := s.Seal(ctx, NewPlaintext(testSecret))
	if err != nil {
		t.Fatal(err)
	}
	if keyID != testKeyName+"/cryptoKeyVersions/1" {
		t.Errorf("kmsKeyID = %q", keyID)
	}
	if strings.Contains(ct, testSecret) || !strings.HasPrefix(ct, "v1.") {
		t.Errorf("sealed text leaks or has no version: %q", ct)
	}
	got, err := s.Open(ctx, ct)
	if err != nil {
		t.Fatal(err)
	}
	if got.Reveal() != testSecret {
		t.Errorf("Open = %q, want the sealed text", got.Reveal())
	}
}

func TestSealFreshDataKeyPerToken(t *testing.T) {
	ctx := context.Background()
	s := newTestSealer(t)
	a, _, _ := s.Seal(ctx, NewPlaintext(testSecret))
	b, _, _ := s.Seal(ctx, NewPlaintext(testSecret))
	if strings.Split(a, ".")[1] == strings.Split(b, ".")[1] {
		t.Error("two seals share one wrapped data key")
	}
}

// flip changes one byte in the given dot-separated part of a sealed text.
func flip(t *testing.T, sealed string, part, at int) string {
	t.Helper()
	parts := strings.Split(sealed, ".")
	raw, err := base64.RawURLEncoding.DecodeString(parts[part])
	if err != nil {
		t.Fatal(err)
	}
	raw[at%len(raw)] ^= 0x01
	parts[part] = base64.RawURLEncoding.EncodeToString(raw)
	return strings.Join(parts, ".")
}

func TestOpenTamperedFails(t *testing.T) {
	ctx := context.Background()
	s := newTestSealer(t)
	ct, _, err := s.Seal(ctx, NewPlaintext(testSecret))
	if err != nil {
		t.Fatal(err)
	}
	other, _, _ := s.Seal(ctx, NewPlaintext("another-fake-token"))
	op := strings.Split(other, ".")
	cp := strings.Split(ct, ".")
	cases := map[string]string{
		"body nonce":       flip(t, ct, 2, 0),
		"body ciphertext":  flip(t, ct, 2, 15),
		"body tag":         flip(t, ct, 2, -1+len(ct)),
		"wrapped key":      flip(t, ct, 1, 20),
		"swapped data key": cp[0] + "." + op[1] + "." + cp[2],
		"truncated":        ct[:len(ct)-4],
		"wrong version":    "v2" + ct[2:],
		"not base64":       "v1.!!.!!",
		"empty":            "",
	}
	for name, bad := range cases {
		t.Run(name, func(t *testing.T) {
			got, err := s.Open(ctx, bad)
			if !errors.Is(err, ErrOpen) {
				t.Fatalf("Open err = %v, want ErrOpen", err)
			}
			if got.Reveal() != "" {
				t.Fatal("a failed Open returned text")
			}
		})
	}
}

func TestOpenOtherKeyFails(t *testing.T) {
	ctx := context.Background()
	kms := NewFakeKMS()
	a, _ := NewSealer(kms, testKeyName)
	b, _ := NewSealer(kms, testKeyName+"-other")
	ct, _, _ := a.Seal(ctx, NewPlaintext(testSecret))
	if _, err := b.Open(ctx, ct); !errors.Is(err, ErrOpen) {
		t.Fatalf("Open under another key: err = %v", err)
	}
}

func TestNewSealerRefusesMissingKey(t *testing.T) {
	if _, err := NewSealer(NewFakeKMS(), " "); err == nil {
		t.Error("empty key name accepted")
	}
	if _, err := NewSealer(nil, testKeyName); err == nil {
		t.Error("nil KMS accepted")
	}
}

type failKMS struct{}

func (failKMS) Encrypt(context.Context, string, []byte) ([]byte, string, error) {
	return nil, "", errors.New("kms down")
}

func (failKMS) Decrypt(context.Context, string, []byte) ([]byte, error) {
	return nil, errors.New("kms down")
}

func TestSealKMSErrorSurfaces(t *testing.T) {
	s, _ := NewSealer(failKMS{}, testKeyName)
	if ct, _, err := s.Seal(context.Background(), NewPlaintext(testSecret)); err == nil || ct != "" {
		t.Fatalf("Seal with KMS down: ct=%q err=%v", ct, err)
	}
}

// TestPlaintextNeverLeaks captures slog (text + JSON handlers), json, and fmt
// output for a Plaintext alone and inside a struct, and fails on the secret.
func TestPlaintextNeverLeaks(t *testing.T) {
	p := NewPlaintext(testSecret)
	holder := struct {
		Channel string
		Token   Plaintext
		Ptr     *Plaintext
	}{"linkedin", p, &p}

	var buf bytes.Buffer
	for _, h := range []slog.Handler{slog.NewTextHandler(&buf, nil), slog.NewJSONHandler(&buf, nil)} {
		log := slog.New(h)
		log.Info("token", "p", p, "ptr", &p, "holder", holder)
		log.Info("token", slog.Any("p", p), slog.String("s", p.String()))
		log.Info(fmt.Sprint(p), "group", slog.GroupValue(slog.Any("p", p)))
	}
	for _, v := range []any{p, &p, holder, map[string]Plaintext{"t": p}, []Plaintext{p}} {
		js, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		buf.Write(js)
	}
	for _, verb := range []string{"%v", "%+v", "%#v", "%s", "%q", "%x"} {
		fmt.Fprintf(&buf, verb+"\n", p)
		fmt.Fprintf(&buf, verb+"\n", holder)
	}
	out := buf.String()
	if strings.Contains(out, testSecret) {
		t.Fatalf("secret leaked:\n%s", out)
	}
	if !strings.Contains(out, redacted) {
		t.Fatalf("no %q in captured output:\n%s", redacted, out)
	}
}
