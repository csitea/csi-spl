package hubclient

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TopicPDFInfo is what the hub says about one topic export (spec 183 7.1.1):
// the file name it chose (7.1.4) and the rows and pictures the PDF holds.
type TopicPDFInfo struct {
	Name     string
	Rows     int
	Pictures int
}

// topicPDFTokens are the export route's refusal tokens (spec 183 7.1.1). A
// 5xx carrying one of them is the hub's answer, not an unreachable hub.
var topicPDFTokens = map[string]bool{
	"not_found": true, "operator_ambiguous": true, "typed_by_not_bound": true, "no_operator": true,
	"too_large": true, "render_unavailable": true, "render_timeout": true,
}

// TopicPDF asks the hub for the PDF of taskID as the person this box works
// for (spec 183 7.1.1: GET /v1/topics/{task_id}/export.pdf with this
// session's box bearer, ?typed_by= when given) and copies the bytes to w. A
// refusal is a *HubError with the route's token and status, and nothing is
// written to w. A body past msg.MaxFileBytes is refused as too_large (413)
// after at most that many bytes reached w: the caller drops its partial file.
func (s *Session) TopicPDF(ctx context.Context, taskID, typedBy string, w io.Writer) (TopicPDFInfo, error) {
	resp, err := s.topicPDFGet(ctx, taskID, typedBy)
	if err != nil {
		return TopicPDFInfo{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return TopicPDFInfo{}, topicPDFRefusal(resp)
	}
	if ct, _, _ := mime.ParseMediaType(resp.Header.Get("Content-Type")); ct != "application/pdf" {
		return TopicPDFInfo{}, fmt.Errorf("%w: GET export.pdf answered 200 with Content-Type %q, not application/pdf",
			ErrUnreachable, resp.Header.Get("Content-Type"))
	}
	n, err := io.Copy(w, io.LimitReader(resp.Body, msg.MaxFileBytes+1))
	if err != nil {
		return TopicPDFInfo{}, err
	}
	if n > msg.MaxFileBytes {
		return TopicPDFInfo{}, &HubError{Token: "too_large", Status: http.StatusRequestEntityTooLarge,
			Detail: fmt.Sprintf("the PDF is over %d bytes", msg.MaxFileBytes)}
	}
	return TopicPDFInfo{
		Name:     topicPDFName(resp.Header.Get("Content-Disposition")),
		Rows:     headerCount(resp.Header, "X-Spool-Rows"),
		Pictures: headerCount(resp.Header, "X-Spool-Pictures"),
	}, nil
}

// topicPDFGet sends the export request with the session's box bearer; the
// response is the caller's to close. No REST timeout of its own: the caller's
// ctx bounds it (a render waits for the renderer's cold start, 1.2 R2).
func (s *Session) topicPDFGet(ctx context.Context, taskID, typedBy string) (*http.Response, error) {
	path := "/v1/topics/" + url.PathEscape(taskID) + "/export.pdf"
	if typedBy != "" {
		path += "?typed_by=" + url.QueryEscape(typedBy)
	}
	u, err := s.c.endpoint(path)
	if err != nil {
		return nil, err
	}
	tok, err := s.uploadToken(ctx)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Accept", "application/pdf")
	if t := s.c.Cfg.TenantID(); t != "" {
		req.Header.Set(TenantHeader, t)
	}
	resp, err := s.c.http().Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: %w", ErrUnreachable, err)
	}
	return resp, nil
}

// topicPDFRefusal reads a non-200 answer: a route token (any status) or any
// 4xx is the hub's refusal; a 5xx with no route token is an unreachable hub.
func topicPDFRefusal(resp *http.Response) error {
	var eb wire.ErrorBody
	json.NewDecoder(io.LimitReader(resp.Body, 8<<10)).Decode(&eb) //nolint:errcheck
	io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))        //nolint:errcheck
	if resp.StatusCode >= 500 && !topicPDFTokens[eb.Error] {
		return fmt.Errorf("%w: GET export.pdf -> %d %s", ErrUnreachable, resp.StatusCode, eb.Error)
	}
	if eb.Error == "" {
		eb.Error = strings.ReplaceAll(strings.ToLower(http.StatusText(resp.StatusCode)), " ", "_")
	}
	return &HubError{Token: eb.Error, Status: resp.StatusCode, Detail: eb.Detail}
}

// topicPDFName is the filename of a Content-Disposition header, kept only
// when it is one plain path element ending .pdf; "" otherwise, and the
// caller names the file.
func topicPDFName(cd string) string {
	_, p, err := mime.ParseMediaType(cd)
	if err != nil {
		return ""
	}
	name := p["filename"]
	if name == "" || strings.HasPrefix(name, ".") || strings.ContainsAny(name, "/\\\x00") ||
		!strings.HasSuffix(strings.ToLower(name), ".pdf") {
		return ""
	}
	return name
}

// headerCount is a non-negative count header; 0 when absent or not a count.
func headerCount(h http.Header, k string) int {
	n, err := strconv.Atoi(strings.TrimSpace(h.Get(k)))
	if err != nil || n < 0 {
		return 0
	}
	return n
}
