package action

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestReadRootKey is specs/047 W17: --root-key takes a file, the key text or
// "-" (stdin), and an error never echoes the value.
func TestReadRootKey(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	text := base64.StdEncoding.EncodeToString(priv)
	file := filepath.Join(t.TempDir(), "root.key")
	if err := os.WriteFile(file, []byte(text+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, tc := range map[string]struct{ v, stdin string }{
		"file":  {file, ""},
		"text":  {text, ""},
		"text+": {" " + text + "\n", ""},
		"stdin": {"-", text + "\n"},
	} {
		got, err := ReadRootKey(tc.v, strings.NewReader(tc.stdin))
		if err != nil || !got.Equal(priv) {
			t.Errorf("%s: got err %v, key match %v", name, err, err == nil && got.Equal(priv))
		}
	}
	// controls: a wrong key, a missing file, an empty stdin - and the key text
	// never appears in the error
	short := base64.StdEncoding.EncodeToString(priv[:32])
	for name, v := range map[string]string{"short": short, "missing": file + ".nope", "stdin": "-"} {
		_, err := ReadRootKey(v, strings.NewReader(""))
		if err == nil {
			t.Errorf("%s: accepted", name)
			continue
		}
		if strings.Contains(err.Error(), short) {
			t.Errorf("%s: the error echoes the key text: %v", name, err)
		}
	}
}
