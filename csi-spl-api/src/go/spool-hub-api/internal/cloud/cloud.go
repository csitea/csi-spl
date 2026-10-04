// Package cloud is the hub's provider factory (spec 076 T003): the one place
// that knows which cloud the hub runs on. SPOOL_CLOUD_PROVIDER picks it, the
// same key the shell reads (do_spl_cloud_provider): gcp (the default, unset
// included), none (docker compose: local files, plain Postgres) or aws
// (phase 2, not built yet). Anything else is a startup error.
package cloud

import (
	"context"
	"fmt"
	"os"
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

// Factory builds every provider seam of one cloud.
type Factory interface {
	Provider() Provider
	Compute() ComputeProvider
	Database() DatabaseProvider
	Secrets() SecretsProvider
	// Blob opens a store on bucket, else on dir; both empty is nil (off).
	Blob(ctx context.Context, bucket, dir string) (blob.Store, error)
}

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

func (gcpFactory) Provider() Provider         { return GCP }
func (f gcpFactory) Compute() ComputeProvider { return gcpCompute{f.env} }
func (gcpFactory) Database() DatabaseProvider { return passDSN{} }
func (f gcpFactory) Secrets() SecretsProvider { return envSecrets{f.env} }

func (gcpFactory) Blob(ctx context.Context, bucket, dir string) (blob.Store, error) {
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

func (noneFactory) Provider() Provider         { return None }
func (f noneFactory) Compute() ComputeProvider { return noneCompute{f.env} }
func (noneFactory) Database() DatabaseProvider { return tcpDSN{} }
func (f noneFactory) Secrets() SecretsProvider { return envSecrets{f.env} }

// Blob is always a local dir; a bucket is a misconfiguration, not a fallback.
func (noneFactory) Blob(_ context.Context, bucket, dir string) (blob.Store, error) {
	if bucket != "" {
		return nil, fmt.Errorf("%s=none takes a local dir, not bucket %q", EnvProvider, bucket)
	}
	if dir == "" {
		return nil, nil
	}
	return blob.Dir{Root: dir}, nil
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
