package config

// The anti-leak startup guard of local dev mode (spec 148 §3.1, §3.2, row
// B4). Local dev mode runs on public default secrets so that `up` needs no
// setup; a hub that is not local dev (SPOOL_HUB_ENV other than lde) refuses
// to start on any of them, or with the one-click dev login switched on.

import (
	"fmt"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/secretfile"
)

// LocalDevEnv is the only SPOOL_HUB_ENV a dev default or the dev login may
// run on: the root docker-compose.yml stack (spec 148 §2).
const LocalDevEnv = "lde"

// DevLoginEnv is the one-click dev login switch (spec 148 §2.3.2, row B3).
// Default off.
const DevLoginEnv = "SPOOL_HUB_AUTH_DEV_LOGIN_ENABLED"

// devDefaultSecrets are the public defaults the local stack ships, keyed by
// the variable a developer overrides them with (spec 148 §3.1): the root
// docker-compose.yml env defaults and csi-spl-api/src/docker/local-secrets.
// They are not secrets; that is why a non-local hub must never run on them.
// The S3 access key id (spool-local-s3-access) is an id, not a secret: the
// documented own-domain stack keeps it and brings its own S3 secret key.
// There is no session key default: the stack mints one on first start.
var devDefaultSecrets = map[string]string{
	"SPOOL_DB_SUPERUSER_PASSWORD": "spool-local-superuser",
	"SPOOL_DB_OWNER_PASSWORD":     "spool-local-owner",
	"SPOOL_DB_RUNTIME_PASSWORD":   "spool-local-runtime",
	"SPOOL_S3_SECRET_KEY":         "spool-local-s3-secret",
}

// ValidateProductionSecrets refuses a dev default secret or the dev login on
// a hub that is not local dev. activeSecrets holds the values the process
// runs with, each under the variable that carries it; a value equal to any
// dev default is refused, whichever variable carries it. The error names the
// variables, never the value.
func ValidateProductionSecrets(env string, activeSecrets map[string]string, devLoginEnabled bool) error {
	if env == LocalDevEnv {
		return nil
	}
	if devLoginEnabled {
		return fmt.Errorf("%s=true is allowed only with SPOOL_HUB_ENV=%s (got %q): the dev login is local dev mode only (spec 148 §3.2)", DevLoginEnv, LocalDevEnv, env)
	}
	names := make([]string, 0, len(activeSecrets))
	for name := range activeSecrets {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		v := activeSecrets[name]
		if v == "" {
			continue
		}
		for key, def := range devDefaultSecrets {
			if v == def {
				return fmt.Errorf("%s holds the public local dev default of %s with SPOOL_HUB_ENV=%q; refusing to start, set your own value (spec 148 §3.2)", name, key, env)
			}
		}
	}
	return nil
}

// checkLeak is LoadHub's guard: it reads the secrets this process holds and
// the dev login switch from the environment.
func (h *Hub) checkLeak() error {
	active, devLogin, err := activeSecrets(os.Getenv, h.DBDSN)
	if err != nil {
		return err
	}
	return ValidateProductionSecrets(h.Env, active, devLogin)
}

// activeSecrets reads the secrets a hub holds: the database password in its
// DSN and the S3 secret key (its _FILE wins, as in internal/blob).
func activeSecrets(getenv func(string) string, dsn string) (map[string]string, bool, error) {
	// The env name stays a literal argument: a const named after a secret
	// is a gosec G101 finding (SPL-2158).
	s3, err := secretfile.Lookup("SPOOL_S3_SECRET_KEY", getenv)
	if err != nil {
		return nil, false, err
	}
	active := map[string]string{"SPOOL_HUB_DB_DSN": dsnPassword(dsn), "SPOOL_S3_SECRET_KEY": s3}
	devLogin := false
	if raw := strings.TrimSpace(getenv(DevLoginEnv)); raw != "" {
		if devLogin, err = strconv.ParseBool(raw); err != nil {
			return nil, false, fmt.Errorf("%s %q must be true or false", DevLoginEnv, raw)
		}
	}
	return active, devLogin, nil
}

// dsnPassword returns the password of a postgres URL or key=value DSN, ""
// when it carries none.
func dsnPassword(dsn string) string {
	dsn = strings.TrimSpace(dsn)
	if strings.Contains(dsn, "://") {
		u, err := url.Parse(dsn)
		if err != nil || u.User == nil {
			return ""
		}
		pw, _ := u.User.Password()
		return pw
	}
	for _, f := range strings.Fields(dsn) {
		if v, ok := strings.CutPrefix(f, "password="); ok {
			return strings.Trim(v, "'")
		}
	}
	return ""
}
