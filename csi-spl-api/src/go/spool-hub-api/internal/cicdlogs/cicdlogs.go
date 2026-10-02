// Package cicdlogs is the M1 stub for spec 008: hub-side fetch of a GitHub
// Actions run log and delivery as a v:1 note + file on the existing bus.
// The M1 image does not include gh; the fetcher is HTTP to a configured API
// base. The feature is flagged off by default.
package cicdlogs

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

const (
	// NotConfiguredBody is the exact note body when the tenant has no token.
	NotConfiguredBody = "CI not configured"
	// TruncationLine is appended to the note body when the log was capped.
	TruncationLine = "log truncated at 32 MiB"
	defaultFromBox = "hub"
	defaultFromID  = "CI-0"
)

// Sentinel errors the hub maps onto the 008 HTTP tokens.
var (
	ErrDisabled    = errors.New("cicd-logs disabled")
	ErrForbidden   = errors.New("repo not allowlisted for this tenant")
	ErrBadRequest  = errors.New("cicd-logs request is malformed")
	ErrFailClosed  = errors.New("cicd-logs secret missing or placeholder in prd")
	ErrNoHubSigner = errors.New("hub box key is not configured")
)

// Request is the POST /v1/cicd-logs body.
type Request struct {
	URL    string `json:"url,omitempty"`
	Owner  string `json:"owner,omitempty"`
	Repo   string `json:"repo,omitempty"`
	RunID  string `json:"run_id,omitempty"`
	Job    string `json:"job,omitempty"`
	TaskID string `json:"task_id"`
	To     string `json:"to"`
	ToBox  string `json:"to_box"`
}

// Result is what Run returns after a bus deliver.
type Result struct {
	Message    *msg.Message
	Delivery   string
	Truncated  bool
	Configured bool
}

// HTTPResult is the JSON body of a successful POST /v1/cicd-logs.
type HTTPResult struct {
	Delivery   string `json:"delivery"`
	MsgID      string `json:"msg_id"`
	TaskID     string `json:"task_id"`
	Configured bool   `json:"configured"`
	Truncated  bool   `json:"truncated,omitempty"`
}

// Fetcher downloads a run (or job) log. Tests inject a fake.
type Fetcher interface {
	FetchLogs(ctx context.Context, token, api, owner, repo, runID, job string) ([]byte, error)
}

// Bus is the hub's blob store + envelope commit. The hub implements it.
type Bus interface {
	PutFile(ctx context.Context, tenant, name string, data []byte) (msg.Attachment, error)
	Deliver(ctx context.Context, tenant string, env *wire.Envelope) (string, error)
}

// Pattern is one allowlist entry: Repo is "*" or an exact name.
type Pattern struct {
	Owner, Repo string
}

// Settings is the parsed 008 hub config. Tokens are never logged.
type Settings struct {
	Enabled      bool
	Env          string
	GitHubAPI    string
	DefaultToken string
	TenantTokens map[string]string
	Allow        map[string][]Pattern // tenant → patterns; missing/empty = deny
	FromBox      string
	FromID       string
}

// Service runs fetch+deliver.
type Service struct {
	Settings     Settings
	Fetch        Fetcher
	Bus          Bus
	Signer       ed25519.PrivateKey
	Now          func() time.Time
	MaxFileBytes int64 // 0 = msg.MaxFileBytes (production)
	MsgVersion   int   // v of the notes it composes, cnf SPOOL_HUB_MSG_VERSION (specs/020); 0 = msg.Version
}

func (s *Service) cap() int64 {
	if s != nil && s.MaxFileBytes > 0 {
		return s.MaxFileBytes
	}
	return msg.MaxFileBytes
}

func (s *Service) writeVersion() int {
	if s != nil && s.MsgVersion != 0 {
		return s.MsgVersion
	}
	return msg.Version
}

func (s *Service) now() time.Time {
	if s != nil && s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Token returns the tenant's token, or false when none / placeholder.
func (s Settings) Token(tenant string) (string, bool) {
	if t, ok := s.TenantTokens[tenant]; ok && !IsPlaceholder(t) {
		return t, true
	}
	if !IsPlaceholder(s.DefaultToken) {
		return s.DefaultToken, true
	}
	return "", false
}

// Allowed reports whether this tenant may fetch owner/repo.
func (s Settings) Allowed(tenant, owner, repo string) bool {
	for _, p := range s.Allow[tenant] {
		if !strings.EqualFold(p.Owner, owner) {
			continue
		}
		if p.Repo == "*" || strings.EqualFold(p.Repo, repo) {
			return true
		}
	}
	return false
}

// ParseSettings builds Settings from the published env strings.
func ParseSettings(enabled bool, env, token, tenantTokens, allowlist, api, fromBox, fromID string) (Settings, error) {
	s := Settings{
		Enabled: enabled, Env: env, GitHubAPI: strings.TrimSpace(api),
		DefaultToken: token, TenantTokens: map[string]string{}, Allow: map[string][]Pattern{},
		FromBox: fromBox, FromID: fromID,
	}
	if s.FromBox == "" {
		s.FromBox = defaultFromBox
	}
	if s.FromID == "" {
		s.FromID = defaultFromID
	}
	for _, part := range splitComma(tenantTokens) {
		tenant, tok, ok := strings.Cut(part, ":")
		tenant, tok = strings.TrimSpace(tenant), strings.TrimSpace(tok)
		if !ok || tenant == "" || tok == "" {
			return Settings{}, fmt.Errorf("SPOOL_HUB_CICD_TENANT_TOKENS entries look like tenant:token")
		}
		s.TenantTokens[tenant] = tok
	}
	al, err := ParseAllowlist(allowlist)
	if err != nil {
		return Settings{}, err
	}
	s.Allow = al
	return s, nil
}

// ParseAllowlist parses `tenant:owner/repo,tenant:owner/*`.
func ParseAllowlist(s string) (map[string][]Pattern, error) {
	out := map[string][]Pattern{}
	for _, part := range splitComma(s) {
		tenant, spec, ok := strings.Cut(part, ":")
		tenant, spec = strings.TrimSpace(tenant), strings.TrimSpace(spec)
		if !ok || tenant == "" || spec == "" {
			return nil, fmt.Errorf("SPOOL_HUB_CICD_REPO_ALLOWLIST entries look like tenant:owner/repo")
		}
		p, err := parsePattern(spec)
		if err != nil {
			return nil, err
		}
		out[tenant] = append(out[tenant], p)
	}
	return out, nil
}

func parsePattern(spec string) (Pattern, error) {
	owner, repo, ok := strings.Cut(spec, "/")
	if !ok || !ident(owner) || repo == "" {
		return Pattern{}, fmt.Errorf("allowlist pattern %q is not owner/repo or owner/*", spec)
	}
	if repo == "*" {
		return Pattern{Owner: owner, Repo: "*"}, nil
	}
	if strings.Contains(owner, "*") {
		return Pattern{}, fmt.Errorf("allowlist pattern %q is too broad", spec)
	}
	if !ident(repo) {
		return Pattern{}, fmt.Errorf("allowlist pattern %q is not owner/repo or owner/*", spec)
	}
	return Pattern{Owner: owner, Repo: repo}, nil
}

func ident(s string) bool {
	if s == "" || s == "*" {
		return false
	}
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '.' || r == '-' {
			continue
		}
		return false
	}
	return true
}

func splitComma(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	var out []string
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// ValidateHubEnv is called from config.LoadHub. When the flag is off it is a
// no-op (M1 default). When on, the API base is required and prd fail-closes
// on a missing/placeholder GitHub token.
func ValidateHubEnv(enabled bool, env, token, tenantTokens, allowlist, api, fromBox, fromID string) error {
	if !enabled {
		return nil
	}
	s, err := ParseSettings(true, env, token, tenantTokens, allowlist, api, fromBox, fromID)
	if err != nil {
		return err
	}
	return s.Validate()
}

// Validate fails fast when the feature is on with a contradictory config.
func (s Settings) Validate() error {
	if !s.Enabled {
		return nil
	}
	if s.GitHubAPI == "" {
		return fmt.Errorf("SPOOL_HUB_CICD_GITHUB_API must be set when cicd-logs is enabled (no default)")
	}
	u, err := url.Parse(s.GitHubAPI)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return fmt.Errorf("SPOOL_HUB_CICD_GITHUB_API %q must be an http(s) URL", s.GitHubAPI)
	}
	if !msg.ValidBoxID(s.FromBox) {
		return fmt.Errorf("SPOOL_HUB_CICD_FROM_BOX %q is not a valid box id", s.FromBox)
	}
	if !msg.ValidID(s.FromID) {
		return fmt.Errorf("SPOOL_HUB_CICD_FROM_ID %q is not a valid agent id", s.FromID)
	}
	if strings.EqualFold(s.Env, "prd") && !s.hasRealToken() {
		return ErrFailClosed
	}
	return nil
}

func (s Settings) hasRealToken() bool {
	if !IsPlaceholder(s.DefaultToken) {
		return true
	}
	for _, t := range s.TenantTokens {
		if !IsPlaceholder(t) {
			return true
		}
	}
	return false
}

// IsPlaceholder reports empty or obvious slot-filler values. It never logs s.
func IsPlaceholder(s string) bool {
	t := strings.TrimSpace(s)
	if t == "" {
		return true
	}
	switch strings.ToUpper(t) {
	case "CHANGE_ME", "CHANGEME", "TODO", "PLACEHOLDER", "REPLACE_ME", "REPLACEME",
		"TBD", "XXX", "YOUR-TOKEN-HERE", "YOUR_TOKEN_HERE":
		return true
	}
	if strings.HasPrefix(t, "<") && strings.HasSuffix(t, ">") {
		return true
	}
	return false
}

// Normalize fills owner/repo/run_id from url when needed.
func (r *Request) Normalize() error {
	if r.TaskID == "" || !msg.ValidID(r.To) || !msg.ValidBoxID(r.ToBox) {
		return fmt.Errorf("%w: task_id, to and to_box are required", ErrBadRequest)
	}
	if r.URL != "" {
		owner, repo, run, job, err := ParseRunURL(r.URL)
		if err != nil {
			return fmt.Errorf("%w: %w", ErrBadRequest, err)
		}
		if r.Owner == "" {
			r.Owner = owner
		}
		if r.Repo == "" {
			r.Repo = repo
		}
		if r.RunID == "" {
			r.RunID = run
		}
		if r.Job == "" {
			r.Job = job
		}
	}
	if !ident(r.Owner) || !ident(r.Repo) || !runIDOK(r.RunID) {
		return fmt.Errorf("%w: url or owner+repo+run_id is required", ErrBadRequest)
	}
	if r.Job != "" && !ident(r.Job) && !runIDOK(r.Job) {
		return fmt.Errorf("%w: job is malformed", ErrBadRequest)
	}
	return nil
}

func runIDOK(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// ParseRunURL extracts owner, repo, run_id and optional job from a run URL.
// The host is caller input; nothing is baked in.
func ParseRunURL(raw string) (owner, repo, runID, job string, err error) {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", "", "", "", fmt.Errorf("run url must be http(s)")
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	// …/{owner}/{repo}/actions/runs/{id}[/job|jobs/{job}]
	for i := 0; i+4 < len(parts); i++ {
		if parts[i+2] == "actions" && parts[i+3] == "runs" && ident(parts[i]) && ident(parts[i+1]) && runIDOK(parts[i+4]) {
			owner, repo, runID = parts[i], parts[i+1], parts[i+4]
			if i+6 < len(parts) && (parts[i+5] == "job" || parts[i+5] == "jobs") {
				job = parts[i+6]
			}
			return owner, repo, runID, job, nil
		}
	}
	return "", "", "", "", fmt.Errorf("run url path is not /owner/repo/actions/runs/{id}")
}

// Run fetches (when configured) and delivers a v:1 note on the bus.
func (s *Service) Run(ctx context.Context, tenant string, req Request) (Result, error) {
	if s == nil || !s.Settings.Enabled {
		return Result{}, ErrDisabled
	}
	if err := req.Normalize(); err != nil {
		return Result{}, err
	}
	tok, ok := s.Settings.Token(tenant)
	if !ok {
		return s.deliverNote(ctx, tenant, req, NotConfiguredBody, nil, false, false)
	}
	if !s.Settings.Allowed(tenant, req.Owner, req.Repo) {
		return Result{}, ErrForbidden
	}
	if s.Fetch == nil {
		return Result{}, fmt.Errorf("cicd-logs fetcher is not configured")
	}
	raw, err := s.Fetch.FetchLogs(ctx, tok, s.Settings.GitHubAPI, req.Owner, req.Repo, req.RunID, req.Job)
	if err != nil {
		return Result{}, scrubErr(err, tok)
	}
	truncated := false
	capn := s.cap()
	if int64(len(raw)) > capn {
		raw = raw[:capn]
		truncated = true
	}
	name := req.Owner + "-" + req.Repo + "-" + req.RunID + ".log"
	att, err := s.Bus.PutFile(ctx, tenant, name, raw)
	if err != nil {
		return Result{}, err
	}
	body := fmt.Sprintf("CI run %s/%s #%s", req.Owner, req.Repo, req.RunID)
	if truncated {
		body += "\n" + TruncationLine
	}
	return s.deliverNote(ctx, tenant, req, body, []msg.Attachment{att}, truncated, true)
}

func (s *Service) deliverNote(ctx context.Context, tenant string, req Request, body string, atts []msg.Attachment, truncated, configured bool) (Result, error) {
	if len(s.Signer) != ed25519.PrivateKeySize {
		return Result{}, ErrNoHubSigner
	}
	if atts == nil {
		atts = []msg.Attachment{}
	}
	m := &msg.Message{
		V: s.writeVersion(), MsgID: uid.New(), TaskID: req.TaskID,
		TS: msg.Now(s.now()), From: s.Settings.FromID, To: req.To, Kind: "note",
		Body: body, Files: atts,
	}
	if err := m.Validate(); err != nil {
		return Result{}, err
	}
	env, err := wire.NewEnvelope(s.Signer, s.Settings.FromBox, req.ToBox, m)
	if err != nil {
		return Result{}, err
	}
	d, err := s.Bus.Deliver(ctx, tenant, env)
	if err != nil {
		return Result{}, err
	}
	return Result{Message: m, Delivery: d, Truncated: truncated, Configured: configured}, nil
}

func scrubErr(err error, token string) error {
	if err == nil {
		return nil
	}
	msg := err.Error()
	if token != "" && strings.Contains(msg, token) {
		msg = strings.ReplaceAll(msg, token, "[redacted]")
	}
	return fmt.Errorf("%s", msg)
}

// MemoryBus is an in-process Bus for unit tests.
type MemoryBus struct {
	Files map[string][]byte // tenant/file_id → bytes
	Envs  []*wire.Envelope
}

// PutFile stores content-addressed bytes.
func (m *MemoryBus) PutFile(_ context.Context, tenant, name string, data []byte) (msg.Attachment, error) {
	if m.Files == nil {
		m.Files = map[string][]byte{}
	}
	sum := sha256.Sum256(data)
	id := hex.EncodeToString(sum[:])
	m.Files[tenant+"/"+id] = append([]byte(nil), data...)
	if name == "" {
		name = id
	}
	return msg.Attachment{Mode: "blob", Kind: "file", FileID: id, SHA256: id, Name: name, Bytes: int64(len(data))}, nil
}

// Deliver records the envelope.
func (m *MemoryBus) Deliver(_ context.Context, _ string, env *wire.Envelope) (string, error) {
	m.Envs = append(m.Envs, env)
	return wire.DeliveryQueued, nil
}

// FakeFetcher is a test Fetcher.
type FakeFetcher struct {
	Logs      map[string][]byte // owner/repo/run_id[/job] → bytes
	Err       error
	LastToken string
	LastAPI   string
}

// FetchLogs returns a fixture or Err.
func (f *FakeFetcher) FetchLogs(_ context.Context, token, api, owner, repo, runID, job string) ([]byte, error) {
	f.LastToken = token
	f.LastAPI = api
	if f.Err != nil {
		return nil, f.Err
	}
	key := owner + "/" + repo + "/" + runID
	if job != "" {
		key += "/" + job
	}
	b, ok := f.Logs[key]
	if !ok {
		return nil, fmt.Errorf("no log fixture for %s", key)
	}
	return append([]byte(nil), b...), nil
}

// HTTPResultFrom builds the REST body.
func HTTPResultFrom(r Result) HTTPResult {
	out := HTTPResult{Delivery: r.Delivery, Configured: r.Configured, Truncated: r.Truncated}
	if r.Message != nil {
		out.MsgID = r.Message.MsgID
		out.TaskID = r.Message.TaskID
	}
	return out
}

// DumpJSON is a test helper (compact).
func DumpJSON(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

var _ Fetcher = (*FakeFetcher)(nil)
var _ Bus = (*MemoryBus)(nil)
