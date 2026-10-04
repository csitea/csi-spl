// Package cloud is the hub's provider factory (spec 076 T003): the one place
// that knows which cloud the hub runs on. SPOOL_CLOUD_PROVIDER picks it, the
// same key the shell reads (do_spl_cloud_provider): gcp (the default, unset
// included), none (docker compose: the embedded S3 service, plain Postgres) or
// aws (phase 2, not built yet). Anything else is a startup error.
package cloud

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
)

// Provider names one cloud.
type Provider string

const (
	GCP  Provider = "gcp"
	None Provider = "none"
	AWS  Provider = "aws"
)

// EnvProvider is the env key that picks the provider.
const EnvProvider = "SPOOL_CLOUD_PROVIDER"

// ComputeProvider is what the hub learns from the runtime it is on.
type ComputeProvider interface {
	// Revision names the deployed revision serving this process; "" lets the
	// hub mint a per-process id.
	Revision() string
}

// DatabaseProvider turns the configured DSN into the one the store opens.
type DatabaseProvider interface {
	DSN(configured string) (string, error)
}

// SecretsProvider resolves a runtime secret by its env name. Both providers
// read the process env today: Cloud Run injects Secret Manager versions as
// env, compose passes them from .env.
type SecretsProvider interface {
	Secret(name string) (string, bool)
}

// BlobStoreProvider opens the hub's two blob stores from their hub config
// (SPOOL_HUB_FILES_* and SPOOL_HUB_DOCS_*).
type BlobStoreProvider interface {
	// Files opens the tenant file store.
	Files(ctx context.Context, bucket, dir string) (blob.Store, error)
	// Docs opens the Docs section's store; nil (off) when nothing is set.
	Docs(ctx context.Context, bucket, dir string) (blob.Store, error)
}

// Factory builds every provider seam of one cloud.
type Factory interface {
	Provider() Provider
	Compute() ComputeProvider
	Database() DatabaseProvider
	Secrets() SecretsProvider
	BlobStore() BlobStoreProvider
}

// The S3 env provider none reads, beside blob.EnvS3* (spec 076 T005 sets them
// in docker-compose.yml). No host, bucket or key is compiled in.
const (
	EnvS3Bucket       = "SPOOL_S3_BUCKET"
	EnvS3UsePathStyle = "SPOOL_S3_USE_PATH_STYLE"
)

// s3DefaultRegion signs requests to a custom endpoint when no region is set:
// a Compose S3 service ignores it, the SDK refuses to sign without one.
const s3DefaultRegion = "us-east-1"

// Env is the process env, swappable in tests.
type Env struct {
	Getenv   func(string) string
	Hostname func() (string, error)
}

// OSEnv reads the real process.
func OSEnv() Env { return Env{Getenv: os.Getenv, Hostname: os.Hostname} }

// New returns the factory SPOOL_CLOUD_PROVIDER names.
func New(env Env) (Factory, error) {
	p, err := ParseProvider(env.Getenv(EnvProvider))
	if err != nil {
		return nil, err
	}
	switch p {
	case GCP:
		return gcpFactory{env: env}, nil
	case None:
		return noneFactory{env: env}, nil
	}
	return nil, fmt.Errorf("%s=%s: the aws provider is not built yet (spec 076 phase 2)", EnvProvider, p)
}

// ParseProvider reads a provider name; "" is gcp, an unknown name an error.
func ParseProvider(s string) (Provider, error) {
	switch p := Provider(strings.TrimSpace(s)); p {
	case "":
		return GCP, nil
	case GCP, None, AWS:
		return p, nil
	default:
		return "", fmt.Errorf("%s=%q: must be gcp, none or aws", EnvProvider, s)
	}
}

type envSecrets struct{ env Env }

func (s envSecrets) Secret(name string) (string, bool) {
	v := s.env.Getenv(name)
	return v, v != ""
}

// gcp: the hub as it ran before this package, choice for choice.
type gcpFactory struct{ env Env }

func (gcpFactory) Provider() Provider           { return GCP }
func (f gcpFactory) Compute() ComputeProvider   { return gcpCompute{f.env} }
func (gcpFactory) Database() DatabaseProvider   { return passDSN{} }
func (f gcpFactory) Secrets() SecretsProvider   { return envSecrets{f.env} }
func (gcpFactory) BlobStore() BlobStoreProvider { return gcpBlob{} }

// gcpBlob: the GCS bucket when one is set, else the dir; both empty is nil.
type gcpBlob struct{}

func (b gcpBlob) Files(ctx context.Context, bucket, dir string) (blob.Store, error) {
	return b.Docs(ctx, bucket, dir)
}

func (gcpBlob) Docs(ctx context.Context, bucket, dir string) (blob.Store, error) {
	switch {
	case bucket != "":
		g, err := blob.OpenGCS(ctx, bucket)
		if err != nil {
			return nil, err // never a typed-nil *GCS inside the interface
		}
		return g, nil
	case dir != "":
		return blob.Dir{Root: dir}, nil
	}
	return nil, nil
}

// gcpCompute: Cloud Run sets K_REVISION.
type gcpCompute struct{ env Env }

func (c gcpCompute) Revision() string { return c.env.Getenv("K_REVISION") }

type passDSN struct{}

func (passDSN) DSN(configured string) (string, error) { return configured, nil }

// none: no cloud SDK client is ever created.
type noneFactory struct{ env Env }

func (noneFactory) Provider() Provider             { return None }
func (f noneFactory) Compute() ComputeProvider     { return noneCompute{f.env} }
func (noneFactory) Database() DatabaseProvider     { return tcpDSN{} }
func (f noneFactory) Secrets() SecretsProvider     { return envSecrets{f.env} }
func (f noneFactory) BlobStore() BlobStoreProvider { return noneBlob{f.env} }

// noneBlob: files live in the S3 service the SPOOL_S3_* env names (owner
// decision 1), never in a local dir; a GCS bucket is a misconfiguration.
type noneBlob struct{ env Env }

// Files ignores SPOOL_HUB_FILES_DIR: the S3 env is the store under none.
func (b noneBlob) Files(ctx context.Context, bucket, _ string) (blob.Store, error) {
	if bucket != "" {
		return nil, fmt.Errorf("%s=none stores files in S3 (%s), not GCS bucket %q", EnvProvider, EnvS3Bucket, bucket)
	}
	opt, err := s3Options(b.env)
	if err != nil {
		return nil, err
	}
	s, err := blob.OpenS3(ctx, opt)
	if err != nil {
		return nil, err // never a typed-nil *S3 inside the interface
	}
	return s, nil
}

// Docs stays a local dir or off under none (spec 075 owns the Docs store).
func (noneBlob) Docs(_ context.Context, bucket, dir string) (blob.Store, error) {
	if bucket != "" {
		return nil, fmt.Errorf("%s=none takes a local docs dir, not bucket %q", EnvProvider, bucket)
	}
	if dir == "" {
		return nil, nil
	}
	return blob.Dir{Root: dir}, nil
}

// s3Options reads the Compose S3 env and fails fast, naming every missing key.
// The credentials stay in the env: blob.OpenS3 reads the pair itself.
func s3Options(env Env) (blob.S3Options, error) {
	var missing []string
	for _, k := range []string{blob.EnvS3Endpoint, EnvS3Bucket, blob.EnvS3AccessKey, blob.EnvS3SecretKey} {
		if strings.TrimSpace(env.Getenv(k)) == "" {
			missing = append(missing, k)
		}
	}
	if len(missing) > 0 {
		return blob.S3Options{}, fmt.Errorf("%s=none stores files in S3: set %s", EnvProvider, strings.Join(missing, ", "))
	}
	// the driver addresses a custom endpoint path-style, always
	if v := strings.TrimSpace(env.Getenv(EnvS3UsePathStyle)); v != "" {
		if ps, err := strconv.ParseBool(v); err != nil || !ps {
			return blob.S3Options{}, fmt.Errorf("%s=%q: provider none addresses %s path-style; leave it unset or true", EnvS3UsePathStyle, v, blob.EnvS3Endpoint)
		}
	}
	region := s3DefaultRegion
	for _, k := range []string{blob.EnvS3Region, "AWS_REGION", "AWS_DEFAULT_REGION"} {
		if v := strings.TrimSpace(env.Getenv(k)); v != "" {
			region = v
			break
		}
	}
	return blob.S3Options{
		Bucket:   strings.TrimSpace(env.Getenv(EnvS3Bucket)),
		Region:   region,
		Endpoint: strings.TrimSpace(env.Getenv(blob.EnvS3Endpoint)),
	}, nil
}

// noneCompute: SPOOL_VERSION when the operator sets it, else the hostname (a
// compose container's id, new on every recreate).
type noneCompute struct{ env Env }

func (c noneCompute) Revision() string {
	if v := strings.TrimSpace(c.env.Getenv("SPOOL_VERSION")); v != "" {
		return v
	}
	if h, err := c.env.Hostname(); err == nil {
		return h
	}
	return ""
}

// tcpDSN refuses a Cloud SQL unix socket: under none Postgres is a TCP host.
type tcpDSN struct{}

func (tcpDSN) DSN(configured string) (string, error) {
	if strings.Contains(configured, "/cloudsql/") {
		return "", fmt.Errorf("%s=none needs a plain TCP Postgres DSN, not a Cloud SQL socket", EnvProvider)
	}
	return configured, nil
}
