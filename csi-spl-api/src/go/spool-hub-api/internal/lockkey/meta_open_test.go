package lockkey

import (
	"crypto/ed25519"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Row r51-07: ReadMeta, openKey and shred on their untested branches, in
// t.TempDir() only, with keys generated here.

// moWriteMeta writes raw as lock.json under a new keys dir and returns it.
func moWriteMeta(t *testing.T, raw string) string {
	t.Helper()
	keysDir := t.TempDir()
	if err := os.MkdirAll(LockDir(keysDir), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(LockDir(keysDir), metaFile), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	return keysDir
}

// moMetaJSON is a lock.json body with version v and the given ids.
func moMetaJSON(v, tenant, box string) string {
	return `{"v": ` + v + `, "tenant_id": "` + tenant + `", "box_id": "` + box + `", "lock_pubkey": "L", "box_pubkey": "B"}`
}

// moSealedKey seals a new key's seed as KindBox under tSecret into a file
// and returns the file's path and the key.
func moSealedKey(t *testing.T) (string, ed25519.PrivateKey) {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "box-"+tBox+".key.enc")
	if err := os.WriteFile(p, sealOne(t, tSecret, tTenant, tBox, KindBox, priv.Seed()), 0o600); err != nil {
		t.Fatal(err)
	}
	return p, priv
}

// moMeta is the Meta openKey binds the sealed file to.
var moMeta = Meta{V: 1, Tenant: tTenant, Box: tBox}

func TestReadMetaNotSealed(t *testing.T) {
	if _, err := ReadMeta(t.TempDir()); !errors.Is(err, ErrNotSealed) {
		t.Fatalf("no lock.json: got %v, want ErrNotSealed", err)
	}
}

func TestReadMetaReadError(t *testing.T) {
	keysDir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(LockDir(keysDir), metaFile), 0o700); err != nil {
		t.Fatal(err)
	}
	_, err := ReadMeta(keysDir)
	if err == nil || errors.Is(err, ErrNotSealed) {
		t.Fatalf("lock.json a directory: got %v, want a read error that is not ErrNotSealed", err)
	}
}

func TestReadMetaMalformed(t *testing.T) {
	cases := map[string]string{
		"invalid json": `{"v": 1,`,
		"v 2":          moMetaJSON("2", tTenant, tBox),
		"bad tenant":   moMetaJSON("1", "Bad Tenant", tBox),
		"bad box":      moMetaJSON("1", tTenant, "Bad Box"),
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := ReadMeta(moWriteMeta(t, raw))
			if err == nil || err.Error() != "lock.json is malformed" {
				t.Fatalf("got %v, want lock.json is malformed", err)
			}
		})
	}
}

func TestReadMetaValid(t *testing.T) {
	m, err := ReadMeta(moWriteMeta(t, moMetaJSON("1", tTenant, tBox)))
	if err != nil {
		t.Fatal(err)
	}
	if want := (Meta{V: 1, Tenant: tTenant, Box: tBox, LockPubkey: "L", BoxPubkey: "B"}); m != want {
		t.Fatalf("got %+v, want %+v", m, want)
	}
}

func TestOpenKeyReadError(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "box-missing.key.enc")
	_, err := openKey(NewOpener([]byte(tSecret)), moMeta, KindBox, missing, "")
	if err == nil || !strings.HasPrefix(err.Error(), "read box-missing.key.enc:") {
		t.Fatalf("got %v, want an error starting read box-missing.key.enc:", err)
	}
}

func TestOpenKeyPubMismatch(t *testing.T) {
	p, _ := moSealedKey(t)
	other, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = openKey(NewOpener([]byte(tSecret)), moMeta, KindBox, p, PubB64(other))
	if err == nil || err.Error() != "the opened key does not match lock.json" {
		t.Fatalf("got %v, want the opened key does not match lock.json", err)
	}
}

func TestOpenKeyMatch(t *testing.T) {
	p, priv := moSealedKey(t)
	got, err := openKey(NewOpener([]byte(tSecret)), moMeta, KindBox, p, PubB64(priv.Public().(ed25519.PublicKey)))
	if err != nil {
		t.Fatal(err)
	}
	if !got.Equal(priv) {
		t.Fatal("openKey returned a different private key")
	}
}

func TestShredBranches(t *testing.T) {
	dir := t.TempDir()
	parent := siPlainFile(t, dir, "parent", []byte("x"))
	if err := shred(filepath.Join(parent, "child")); err == nil {
		t.Fatal("shred under a regular file (stat ENOTDIR) did not fail")
	}
	if err := shred(filepath.Join(dir, "missing")); err != nil {
		t.Fatalf("missing path: %v", err)
	}
	if err := shred(parent); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(parent); !os.IsNotExist(err) {
		t.Fatalf("shredded file still there: %v", err)
	}
}
