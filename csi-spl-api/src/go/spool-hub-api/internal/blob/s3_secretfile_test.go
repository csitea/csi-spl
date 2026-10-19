package blob

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// SPL-2158: the compose stack hands the S3 secret over as a Docker secret file
// (SPOOL_S3_SECRET_KEY_FILE); the plain env var stays for lde.
func TestS3SecretKeyFile(t *testing.T) {
	f := filepath.Join(t.TempDir(), "s3_secret_key")
	if err := os.WriteFile(f, []byte("from-file\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	secret := func() (string, error) {
		s, err := OpenS3(context.Background(), S3Options{Bucket: "bkt", Region: "eu-north-1", Endpoint: "http://127.0.0.1:1"})
		if err != nil {
			return "", err
		}
		c, err := s.client.Options().Credentials.Retrieve(context.Background())
		return c.SecretAccessKey, err
	}
	t.Setenv(EnvS3AccessKey, "test-access-key")
	t.Setenv(EnvS3SecretKey, "from-env")

	t.Setenv(EnvS3SecretKey+"_FILE", f)
	if got, err := secret(); err != nil || got != "from-file" {
		t.Fatalf("the file must win over the env var: %q %v", got, err)
	}
	t.Setenv(EnvS3SecretKey+"_FILE", "")
	if got, err := secret(); err != nil || got != "from-env" {
		t.Fatalf("the env var is the fallback: %q %v", got, err)
	}
	t.Setenv(EnvS3SecretKey+"_FILE", f+".absent")
	if _, err := OpenS3(context.Background(), S3Options{Bucket: "bkt", Region: "eu-north-1"}); err == nil ||
		!strings.Contains(err.Error(), EnvS3SecretKey+"_FILE") {
		t.Fatalf("an unreadable secret file must fail, naming it: %v", err)
	}
}
