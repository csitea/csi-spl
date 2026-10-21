package config

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// The operator's example env file (spec 044 FR-OS-003, T020) and the module
// whose readers it documents, relative to this package.
const (
	exampleEnvFile = "../../../../../../example.env.yaml"
	exampleEnvRoot = "../../../../../../csi-spl-api"
	hubModuleDir   = "../.."
)

var (
	// a struct field read by caarlos0/env: env:"KEY"
	envTagRe = regexp.MustCompile(`env:"([A-Z0-9_]+)"`)
	// a named env key: SearchIndexEnv = "SPOOL_HUB_SEARCH_INDEX"
	envConstRe = regexp.MustCompile(`(?m)^\s*(?:const\s+)?\w*Env\w*\s*=\s*"((?:SPOOL_HUB|SPOOL_S3|SPOOL_CLOUD|SPOOL_GITHUB)_[A-Z0-9_]+)"`)
	// a hub key read in place: os.Getenv("SPOOL_HUB_OPERATOR_EMAILS")
	envReadRe = regexp.MustCompile(`os\.(?:Getenv|LookupEnv)\("(SPOOL_HUB_[A-Z0-9_]+)"\)`)
	// a key line of example.env.yaml: two spaces, KEY: value
	exampleKeyRe = regexp.MustCompile(`(?m)^  ([A-Z][A-Z0-9_]*):(.*)$`)
	// a URL in a value: its host must be a placeholder host
	exampleURLRe = regexp.MustCompile(`https?://([^/"\s:]+)`)
)

// hubEnvKeys is every env key the hub's readers take, from the non-test
// sources of the module.
func hubEnvKeys(t *testing.T) map[string]string {
	t.Helper()
	keys := map[string]string{}
	err := filepath.WalkDir(hubModuleDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(p, ".go") || strings.HasSuffix(p, "_test.go") {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		for _, re := range []*regexp.Regexp{envTagRe, envConstRe, envReadRe} {
			for _, m := range re.FindAllStringSubmatch(string(b), -1) {
				keys[m[1]] = p
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return keys
}

// missingKeys lists the keys the example text does not name, sorted.
func missingKeys(keys map[string]string, example string) []string {
	listed := map[string]bool{}
	for _, m := range exampleKeyRe.FindAllStringSubmatch(example, -1) {
		listed[m[1]] = true
	}
	var out []string
	for k := range keys {
		if !listed[k] {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// TestExampleEnvListsEveryHubKey: a stranger builds a hub from
// example.env.yaml alone, so every variable a hub reader takes is in it.
func TestExampleEnvListsEveryHubKey(t *testing.T) {
	if _, err := os.Stat(exampleEnvRoot); os.IsNotExist(err) {
		t.Skip("no repository root in this checkout (a csi-spl-api-only build context)")
	}
	b, err := os.ReadFile(exampleEnvFile)
	if err != nil {
		t.Fatalf("the repository root has no example.env.yaml (spec 044 T020): %v", err)
	}
	example := string(b)
	keys := hubEnvKeys(t)
	if len(keys) < 200 {
		t.Fatalf("read only %d hub env keys: the scan lost its readers", len(keys))
	}
	for _, k := range missingKeys(keys, example) {
		t.Errorf("example.env.yaml does not list %s (read in %s): add it with a placeholder and the doc comment", k, keys[k])
	}
	// placeholders only: every URL host in a value is example.com or under it
	for _, kv := range exampleKeyRe.FindAllStringSubmatch(example, -1) {
		for _, m := range exampleURLRe.FindAllStringSubmatch(kv[2], -1) {
			if h := m[1]; h != "example.com" && !strings.HasSuffix(h, ".example.com") {
				t.Errorf("example.env.yaml gives %s the host %q: use example.com", kv[1], h)
			}
		}
	}

	// CONTROLS: the checks cannot pass vacuously.
	dropped := strings.Replace(example, "\n  SPOOL_HUB_DB_DSN:", "\n  # SPOOL_HUB_DB_DSN:", 1)
	if dropped == example || len(missingKeys(keys, dropped)) != 1 {
		t.Error("CONTROL a key removed from the file did not read as missing")
	}
	if keys["SPOOL_HUB_OPERATOR_EMAILS"] == "" || keys["SPOOL_HUB_SEARCH_INDEX"] == "" || keys["SPOOL_HUB_MAIL_SMTP_HOST"] == "" {
		t.Error("CONTROL a read in place, a named key or a struct tag was not scanned")
	}
	if !exampleURLRe.MatchString(`"https://api.example.net"`) || strings.HasSuffix("api.example.net", ".example.com") {
		t.Error("CONTROL a foreign host would not be refused")
	}
}
