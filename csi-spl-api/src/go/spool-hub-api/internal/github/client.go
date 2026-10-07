// Package github is the hub's GitHub App client for Repo Docs edits (spec
// 075 repo-edit §6, §9; T09). It signs a JWT with the App private key,
// exchanges it for an installation token cached in memory for 50 min, and
// speaks the few Git Data API calls the edit worker needs: the head blob of
// a path, one fast-forward commit, and a compare. Nothing here touches the
// store; no key, JWT or token byte is ever logged or put in an error.
package github

import (
	"bytes"
	"context"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog"
)

// TokenTTL is how long an installation token is reused. GitHub issues it for
// 1 h; the margin covers clock skew and a slow request (spec §9).
const TokenTTL = 50 * time.Minute

// Config names the App, the repo and the branch. API is cnf
// env.docs.repo_edit.github_api (a fake in every test); Key is the PEM the
// hub reads from SPOOL_GITHUB_APP_KEY. Noreply is the domain of the bot's
// committer address; "" derives it from API (users.noreply.<host>).
type Config struct {
	API            string
	AppID          string
	InstallationID string
	Owner, Repo    string
	Branch         string
	Key            []byte
	Noreply        string
	HTTP           *http.Client
	Log            zerolog.Logger
	Now            func() time.Time
}

// Client is safe for concurrent use.
type Client struct {
	api, appID, inst, owner, repo, branch, noreply string

	key  *rsa.PrivateKey
	http *http.Client
	log  zerolog.Logger
	now  func() time.Time

	mu       sync.Mutex
	token    string
	tokenExp time.Time

	botMu sync.Mutex
	bot   Identity
}

// New parses the key once; the error never quotes it.
func New(cfg Config) (*Client, error) {
	key, err := parseKey(cfg.Key)
	if err != nil {
		return nil, err
	}
	if cfg.API == "" || cfg.AppID == "" || cfg.InstallationID == "" || cfg.Owner == "" || cfg.Repo == "" {
		return nil, errors.New("github: API, AppID, InstallationID, Owner and Repo are required")
	}
	c := &Client{
		api: strings.TrimRight(cfg.API, "/"), appID: cfg.AppID, inst: cfg.InstallationID,
		owner: cfg.Owner, repo: cfg.Repo, branch: cfg.Branch, noreply: cfg.Noreply,
		key: key, http: cfg.HTTP, log: cfg.Log, now: cfg.Now,
	}
	if c.noreply == "" {
		c.noreply = noreplyDomain(c.api)
	}
	if c.branch == "" {
		c.branch = "master"
	}
	if c.http == nil {
		c.http = &http.Client{Timeout: 30 * time.Second}
	}
	if c.now == nil {
		c.now = time.Now
	}
	return c, nil
}

// installationToken returns the cached token, minting a new one when the
// cache is empty or older than TokenTTL.
func (c *Client) installationToken(ctx context.Context) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.token != "" && c.now().Before(c.tokenExp) {
		return c.token, nil
	}
	jwt, err := c.appJWT()
	if err != nil {
		return "", err
	}
	var out struct {
		Token string `json:"token"`
	}
	path := "/app/installations/" + c.inst + "/access_tokens"
	if err := c.do(ctx, "token", http.MethodPost, path, "Bearer "+jwt, nil, &out); err != nil {
		return "", err
	}
	if out.Token == "" {
		return "", &APIError{Op: "token", Status: http.StatusBadGateway, Message: "empty installation token"}
	}
	c.token, c.tokenExp = out.Token, c.now().Add(TokenTTL)
	c.log.Info().Str("installation", c.inst).Msg("github: installation token minted")
	return c.token, nil
}

// dropToken forgets a token GitHub refused, so the next call mints afresh.
func (c *Client) dropToken() {
	c.mu.Lock()
	c.token, c.tokenExp = "", time.Time{}
	c.mu.Unlock()
}

// call runs one repo API request under the installation token.
func (c *Client) call(ctx context.Context, op, method, path string, in, out any) error {
	tok, err := c.installationToken(ctx)
	if err != nil {
		return err
	}
	err = c.do(ctx, op, method, path, "token "+tok, in, out)
	var ae *APIError
	if errors.As(err, &ae) && ae.Status == http.StatusUnauthorized {
		c.dropToken()
	}
	return err
}

// do sends one request. auth is the Authorization header value; it is never
// logged and never part of an error.
func (c *Client) do(ctx context.Context, op, method, path, auth string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return fmt.Errorf("github %s: %w", op, err)
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, c.api+path, body)
	if err != nil {
		return fmt.Errorf("github %s: %w", op, err)
	}
	req.Header.Set("Authorization", auth)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		c.log.Warn().Str("op", op).Msg("github: request failed before an answer")
		return &APIError{Op: op, Message: "network: " + err.Error()}
	}
	defer func() { _ = resp.Body.Close() }()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if resp.StatusCode/100 != 2 {
		ae := &APIError{Op: op, Status: resp.StatusCode, Message: messageOf(raw)}
		c.log.Warn().Str("op", op).Int("status", resp.StatusCode).Str("message", ae.Message).Msg("github: request refused")
		return ae
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(raw, out); err != nil {
		return &APIError{Op: op, Status: resp.StatusCode, Message: "undecodable answer"}
	}
	return nil
}

// messageOf keeps GitHub's "message" field only, never the raw body.
func messageOf(raw []byte) string {
	var m struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(raw, &m) != nil {
		return ""
	}
	if len(m.Message) > 200 {
		return m.Message[:200]
	}
	return m.Message
}
