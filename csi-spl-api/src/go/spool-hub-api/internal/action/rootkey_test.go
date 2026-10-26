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

// TestReadRootKeyMissingFile is spec 158 row C: a --root-key path with no
// file behind it says the file does not exist, in plain words; a bad key
// text keeps the key message. Control: before the fix the missing file read
// "the --root-key text is not a base64 ed25519 private key (nor a readable file)".
func TestReadRootKeyMissingFile(t *testing.T) {
	dir := t.TempDir()
	for name, v := range map[string]string{
		"abs":   filepath.Join(dir, "root.key"),
		"home":  "~/.spool/root.key",
		"rel":   "./root.key",
		"plain": "root-key.b64",
	} {
		_, err := ReadRootKey(v, strings.NewReader(""))
		if err == nil || !strings.Contains(err.Error(), "the root key file does not exist") {
			t.Errorf("%s: want the plain missing-file error, got %v", name, err)
		}
		if err != nil && strings.Contains(err.Error(), v) {
			t.Errorf("%s: the error echoes the value: %v", name, err)
		}
	}
	if _, err := ReadRootKey(dir, strings.NewReader("")); err == nil || !strings.Contains(err.Error(), "is a directory") {
		t.Errorf("dir: want the directory error, got %v", err)
	}
	if _, err := ReadRootKey("AAAA", strings.NewReader("")); err == nil || !strings.Contains(err.Error(), "not a base64 ed25519 private key") {
		t.Errorf("bad text: want the key error, got %v", err)
	}
}
