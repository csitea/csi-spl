package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestValidateProductionSecrets: every public dev default and the dev login
// are refused on dev and prd (and any env that is not lde), accepted on lde
// (spec 148 §3.2, row B4).
func TestValidateProductionSecrets(t *testing.T) {
	if err := ValidateProductionSecrets("prd", map[string]string{"SPOOL_HUB_DB_DSN": "a-real-one"}, false); err != nil {
		t.Fatalf("prd with own secrets refused: %v", err)
	}
	for _, env := range []string{"dev", "prd", "", "stg"} {
		if err := ValidateProductionSecrets(env, nil, true); err == nil || !strings.Contains(err.Error(), DevLoginEnv) {
			t.Fatalf("env %q: dev login on accepted (err %v)", env, err)
		}
		for key, def := range devDefaultSecrets {
			err := ValidateProductionSecrets(env, map[string]string{"SPOOL_HUB_DB_DSN": def}, false)
			if err == nil || !strings.Contains(err.Error(), key) {
				t.Fatalf("env %q: default of %s accepted (err %v)", env, key, err)
			}
			if strings.Contains(err.Error(), def) {
				t.Fatalf("env %q: the error leaks the value: %v", env, err)
			}
		}
	}
	for _, def := range devDefaultSecrets {
		if err := ValidateProductionSecrets(LocalDevEnv, map[string]string{"SPOOL_S3_SECRET_KEY": def}, true); err != nil {
			t.Fatalf("lde refused its own defaults: %v", err)
		}
	}
}

// TestValidateProductionSecretsLoadHub: LoadHub runs the guard on what the
// compose stack hands the hub (the DSN password, the S3 secret key file, the
// dev login switch).
func TestValidateProductionSecretsLoadHub(t *testing.T) {
	setHubBase(t)
	t.Setenv("SPOOL_S3_SECRET_KEY", "")
	t.Setenv("SPOOL_S3_SECRET_KEY_FILE", "")
	t.Setenv(DevLoginEnv, "")
	compose := "postgres://spool_hub_rt:spool-local-runtime@pg:5432/spool_hub?sslmode=disable"

	t.Setenv("SPOOL_HUB_ENV", "lde")
	t.Setenv("SPOOL_HUB_DB_DSN", compose)
	t.Setenv(DevLoginEnv, "true")
	if _, err := LoadHub(); err != nil {
		t.Fatalf("lde compose defaults refused: %v", err)
	}

	for _, env := range []string{"dev", "prd"} {
		t.Setenv("SPOOL_HUB_ENV", env)
		t.Setenv(DevLoginEnv, "true")
		t.Setenv("SPOOL_HUB_DB_DSN", "postgres://rt:own-pw@db/spool")
		if _, err := LoadHub(); err == nil || !strings.Contains(err.Error(), DevLoginEnv) {
			t.Fatalf("%s: dev login on accepted (err %v)", env, err)
		}
		t.Setenv(DevLoginEnv, "false")
		if _, err := LoadHub(); err != nil {
			t.Fatalf("%s with own secrets refused: %v", env, err)
		}
		t.Setenv("SPOOL_HUB_DB_DSN", compose)
		if _, err := LoadHub(); err == nil || !strings.Contains(err.Error(), "SPOOL_DB_RUNTIME_PASSWORD") {
			t.Fatalf("%s: default runtime password accepted (err %v)", env, err)
		}
		t.Setenv("SPOOL_HUB_DB_DSN", "host=pg user=o password=spool-local-owner dbname=spool")
		if _, err := LoadHub(); err == nil || !strings.Contains(err.Error(), "SPOOL_DB_OWNER_PASSWORD") {
			t.Fatalf("%s: default owner password in a key=value DSN accepted (err %v)", env, err)
		}
		t.Setenv("SPOOL_HUB_DB_DSN", "postgres://rt:own-pw@db/spool")
		f := filepath.Join(t.TempDir(), "s3_secret_key")
		if err := os.WriteFile(f, []byte("spool-local-s3-secret\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		t.Setenv("SPOOL_S3_SECRET_KEY_FILE", f)
		if _, err := LoadHub(); err == nil || !strings.Contains(err.Error(), "SPOOL_S3_SECRET_KEY") {
			t.Fatalf("%s: default S3 secret key file accepted (err %v)", env, err)
		}
		t.Setenv("SPOOL_S3_SECRET_KEY_FILE", "")
	}
}
