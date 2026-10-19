package cloud

import (
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
)

// SPL-2158: the compose stack names the S3 secret by its file
// (SPOOL_S3_SECRET_KEY_FILE, a Docker secret); that counts as set.
func TestNoneS3SecretByFile(t *testing.T) {
	kv := composeS3()
	delete(kv, blob.EnvS3SecretKey)
	kv[blob.EnvS3SecretKey+"_FILE"] = "/run/secrets/spool_s3_secret_key"
	if _, err := s3Options(fakeEnv(kv, "h")); err != nil {
		t.Fatalf("s3Options with the secret as a file: %v", err)
	}
	kv[blob.EnvS3SecretKey+"_FILE"] = " "
	if _, err := s3Options(fakeEnv(kv, "h")); err == nil {
		t.Fatal("a blank _FILE and no secret accepted")
	}
}
