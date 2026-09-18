package cicdlogs

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// HTTPFetcher GETs Actions logs from Settings.GitHubAPI. Authorization is
// stripped on redirect so a 302 to a signed blob URL is not sent the token.
type HTTPFetcher struct {
	Client *http.Client
}

func (f HTTPFetcher) client() *http.Client {
	if f.Client != nil {
		return f.Client
	}
	return &http.Client{Timeout: 60 * time.Second, CheckRedirect: stripAuthRedirect}
}

func stripAuthRedirect(req *http.Request, via []*http.Request) error {
	req.Header.Del("Authorization")
	if len(via) >= 10 {
		return fmt.Errorf("too many redirects")
	}
	return nil
}

// FetchLogs implements Fetcher. api is the caller-configured base; there is
// no baked host. The token is never included in the returned error.
func (f HTTPFetcher) FetchLogs(ctx context.Context, token, api, owner, repo, runID, job string) ([]byte, error) {
	if token == "" {
		return nil, fmt.Errorf("github logs: missing token")
	}
	base := strings.TrimRight(api, "/")
	var loc string
	if job != "" {
		loc = fmt.Sprintf("%s/repos/%s/%s/actions/jobs/%s/logs", base, owner, repo, job)
	} else {
		loc = fmt.Sprintf("%s/repos/%s/%s/actions/runs/%s/logs", base, owner, repo, runID)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, loc, nil)
	if err != nil {
		return nil, fmt.Errorf("github logs: %s", scrub(err.Error(), token))
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "spool-hub-cicd-logs")
	resp, err := f.client().Do(req)
	if err != nil {
		return nil, fmt.Errorf("github logs: %s", scrub(err.Error(), token))
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, msg.MaxFileBytes+1))
	if err != nil {
		return nil, fmt.Errorf("github logs: %s", scrub(err.Error(), token))
	}
	if resp.StatusCode >= 300 {
		return nil, fmt.Errorf("github logs: HTTP %d", resp.StatusCode)
	}
	return body, nil
}

func scrub(s, token string) string {
	if token != "" && strings.Contains(s, token) {
		return strings.ReplaceAll(s, token, "[redacted]")
	}
	return s
}
