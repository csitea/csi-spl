package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// marketing-publish (SPL-1855; owner HUM-10, topic f46301d4 msgs 54795a30,
// c5ed6345): an agent publishes one live blog post on the workspace owner's
// connected LinkedIn channel, for that owner:
//
//	marketing-publish <post-id> --for <HUM-id>
//
// POST /v1/marketing/posts/{id}/publish with the box's role=cli upload token
// and X-Spool-Requester: <HUM-id>. The hub keeps every gate: the workspace
// allow-listed and switched on, the requester its owner, the owner's own
// channel, once per post (a second publish answers 409).

var (
	marketingPostRe = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*$`)
	marketingHumRe  = regexp.MustCompile(`^HUM-[A-Za-z0-9_-]+$`)
)

func cmdMarketingPublish(cfg *config.Config, args []string) int {
	const usage = "usage: spool marketing-publish <post-id> --for <HUM-id>"
	fs := flag.NewFlagSet("marketing-publish", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	fs.Usage = func() { fmt.Fprintln(fs.Output(), usage) }
	forHum := fs.String("for", "", "the workspace owner the post is published for (HUM-...)")
	if err := fs.Parse(forFirst(args)); err != nil {
		return 1
	}
	if fs.NArg() != 1 {
		return fail(errors.New(usage))
	}
	post, hum := fs.Arg(0), strings.TrimSpace(*forHum)
	if !marketingPostRe.MatchString(post) {
		return fail(fmt.Errorf("post id %q is not a blog post id (YYYY-MM-DD-slug)", post))
	}
	if !marketingHumRe.MatchString(hum) {
		return fail(errors.New("--for must name the workspace owner's HUM-... id"))
	}
	ctx, stop := interruptible()
	defer stop()
	out, err := marketingPublishCall(ctx, cfg, post, hum)
	if err != nil {
		return fail(err)
	}
	return writeStdout(out, true)
}

// forFirst moves --for <v> ahead of the post id so flag.FlagSet sees it.
func forFirst(args []string) []string {
	var flags, pos []string
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case (a == "--for" || a == "-for") && i+1 < len(args):
			flags = append(flags, a, args[i+1])
			i++
		case strings.HasPrefix(a, "--for=") || strings.HasPrefix(a, "-for="):
			flags = append(flags, a)
		default:
			pos = append(pos, a)
		}
	}
	return append(flags, pos...)
}

// marketingPublishCall performs the publish and returns the hub's body.
func marketingPublishCall(ctx context.Context, cfg *config.Config, post, hum string) ([]byte, error) {
	if strings.TrimSpace(cfg.HubURL) == "" {
		return nil, errors.New("marketing-publish needs hub mode ($SPOOL_HUB_URL is not set)")
	}
	if cfg.TenantID() == "" {
		return nil, errors.New("marketing-publish needs a tenant ($SPOOL_TENANT, or a tenant host in $SPOOL_HUB_URL)")
	}
	if _, ok := ctx.Deadline(); !ok {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, docRESTTimeout)
		defer cancel()
	}
	c := hubclient.New(cfg)
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	tok, err := sess.UploadToken(ctx)
	if err != nil {
		return nil, err
	}
	path := "/v1/marketing/posts/" + url.PathEscape(post) + "/publish"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, docEndpoint(cfg.HubURL, path), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set(hubclient.TenantHeader, cfg.TenantID())
	req.Header.Set("X-Spool-Requester", hum)
	resp, err := c.HTTPClient().Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: POST %s: %w", hubclient.ErrUnreachable, path, err)
	}
	defer resp.Body.Close()
	b, err := readLimited(resp.Body, 8<<10)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, marketingPublishError(resp.StatusCode, b)
	}
	return b, nil
}

// marketingPublishError names the hub's refusal: its error code and detail.
func marketingPublishError(status int, body []byte) error {
	var eb struct {
		Error  string `json:"error"`
		Detail string `json:"detail"`
	}
	_ = json.Unmarshal(body, &eb) //nolint:errcheck // a non-JSON body is printed raw below
	why := strings.TrimSpace(eb.Error + ": " + eb.Detail)
	if eb.Error == "" && eb.Detail == "" {
		why = strings.TrimSpace(string(body))
	}
	return fmt.Errorf("publish refused, hub answered %d (%s)", status, why)
}
