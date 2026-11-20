// SPDX-License-Identifier: AGPL-3.0-only

package topicpdf

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"google.golang.org/api/idtoken"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
)

// Renderer turns the HTML of HTML into PDF bytes (spec 183 7.1.5).
type Renderer interface {
	Render(ctx context.Context, html []byte) ([]byte, error)
}

// DefaultTimeout is cnf hub.pdf.timeout's default (spec 183 1.2 R2): a cold
// start of the renderer plus one render.
const DefaultTimeout = 120 * time.Second

// The render errors and the hub answer each maps to (Status).
var (
	// ErrUnavailable: no renderer URL, or the renderer cannot be reached or
	// failed the render -> 503 render_unavailable.
	ErrUnavailable = errors.New("render_unavailable")
	// ErrBusy: the renderer's 429, or Cloud Run's 429 / 503 when no instance
	// can start -> 503 render_unavailable.
	ErrBusy = fmt.Errorf("%w: renderer busy", ErrUnavailable)
	// ErrTimeout: past the wait (hub.pdf.timeout) -> 504 render_timeout. It
	// also matches context.DeadlineExceeded.
	ErrTimeout = errors.New("render_timeout")
	// ErrTooLarge: a PDF over msg.MaxFileBytes, or an HTML over the
	// renderer's cap -> 413 too_large.
	ErrTooLarge = errors.New("too_large")
)

// Status is the hub's answer to a render error (spec 183 7.1.1): the HTTP
// status and the error token. A nil error is 200 "".
func Status(err error) (int, string) {
	switch {
	case err == nil:
		return http.StatusOK, ""
	case errors.Is(err, ErrTimeout), errors.Is(err, context.DeadlineExceeded):
		return http.StatusGatewayTimeout, "render_timeout"
	case errors.Is(err, ErrTooLarge):
		return http.StatusRequestEntityTooLarge, "too_large"
	}
	return http.StatusServiceUnavailable, "render_unavailable"
}

// HTTPRenderer posts the HTML to the renderer service's POST <URL>/render
// (spec 183 7.1.6) as the hub's own identity: an ID token for URL, through
// idtoken.NewClient. URL is the hub's env SPOOL_PDF_URL; empty answers
// ErrUnavailable (lde, tests without a renderer).
type HTTPRenderer struct {
	URL string
	// Timeout is the wait for one render, cold start included; 0 =
	// DefaultTimeout. A deadline already on the context is kept when sooner.
	Timeout time.Duration
	// Client replaces the ID-token client (tests); nil = idtoken.NewClient.
	Client *http.Client
}

// Render answers the PDF, or ErrUnavailable, ErrBusy, ErrTimeout or
// ErrTooLarge.
func (r HTTPRenderer) Render(ctx context.Context, html []byte) ([]byte, error) {
	if strings.TrimSpace(r.URL) == "" {
		return nil, fmt.Errorf("%w: no renderer URL (SPOOL_PDF_URL)", ErrUnavailable)
	}
	wait := r.Timeout
	if wait <= 0 {
		wait = DefaultTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, wait)
	defer cancel()
	client := r.Client
	if client == nil {
		c, err := idtoken.NewClient(ctx, r.URL)
		if err != nil {
			return nil, fmt.Errorf("%w: id token: %v", ErrUnavailable, err)
		}
		client = c
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(r.URL, "/")+"/render", bytes.NewReader(html))
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	req.Header.Set("Content-Type", "text/html; charset=utf-8")
	resp, err := client.Do(req)
	if err != nil {
		return nil, timeoutOr(ctx, err)
	}
	defer func() { _ = resp.Body.Close() }()
	return readPDF(ctx, resp)
}

// readPDF reads a 200's body up to msg.MaxFileBytes; any other status is
// mapped to its error, with the start of the renderer's answer.
func readPDF(ctx context.Context, resp *http.Response) ([]byte, error) {
	if resp.StatusCode != http.StatusOK {
		detail, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return nil, statusErr(resp.StatusCode, strings.TrimSpace(string(detail)))
	}
	pdf, err := io.ReadAll(io.LimitReader(resp.Body, msg.MaxFileBytes+1))
	if err != nil {
		return nil, timeoutOr(ctx, err)
	}
	if len(pdf) > msg.MaxFileBytes {
		return nil, fmt.Errorf("%w: the PDF is over %d bytes", ErrTooLarge, msg.MaxFileBytes)
	}
	return pdf, nil
}

func statusErr(code int, detail string) error {
	switch code {
	case http.StatusTooManyRequests, http.StatusServiceUnavailable:
		return fmt.Errorf("%w (%d)", ErrBusy, code)
	case http.StatusRequestEntityTooLarge:
		return fmt.Errorf("%w: the renderer refused the HTML (413)", ErrTooLarge)
	case http.StatusGatewayTimeout:
		return fmt.Errorf("%w: %w (504)", ErrTimeout, context.DeadlineExceeded)
	}
	return fmt.Errorf("%w: renderer answered %d: %s", ErrUnavailable, code, detail)
}

// timeoutOr is ErrTimeout when ctx's deadline passed, else ErrUnavailable.
func timeoutOr(ctx context.Context, err error) error {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return fmt.Errorf("%w: %w", ErrTimeout, context.DeadlineExceeded)
	}
	return fmt.Errorf("%w: %v", ErrUnavailable, err)
}
