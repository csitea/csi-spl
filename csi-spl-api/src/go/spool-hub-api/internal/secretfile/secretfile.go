// Package secretfile reads a secret the way the compose stack hands it over:
// a Docker secret file named by <NAME>_FILE (mounted under /run/secrets), with
// the plain <NAME> env var as the fallback for lde and Cloud Run (SPL-2158,
// security action 1).
package secretfile

import (
	"fmt"
	"os"
	"strings"
)

// Suffix names the file variant of an env var: SPOOL_S3_SECRET_KEY_FILE.
const Suffix = "_FILE"

// Lookup returns the value of the secret name. When name+Suffix is set, the
// file it names wins and the env var is not read; an unreadable file is an
// error, never a silent fall back. Otherwise it is getenv(name), "" when unset,
// so the caller's own "must be set" check still decides. Trailing line breaks
// are dropped (`echo value >file` writes one), as the shell's $(cat file) does
// in hub-entrypoint.sh.
func Lookup(name string, getenv func(string) string) (string, error) {
	path := strings.TrimSpace(getenv(name + Suffix))
	if path == "" {
		return getenv(name), nil
	}
	b, err := os.ReadFile(path) // #nosec G304 -- the operator names the secret file
	if err != nil {
		return "", fmt.Errorf("%s%s: cannot read the secret file: %w", name, Suffix, err)
	}
	return strings.TrimRight(string(b), "\r\n"), nil
}
