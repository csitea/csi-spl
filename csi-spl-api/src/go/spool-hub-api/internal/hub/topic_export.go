package hub

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/topicpdf"
)

// Spec 183 7.1.1: GET /v1/topics/{task_id}/export.pdf[?typed_by=HUM-n]. A
// box, by the upload token its session was issued (as GET /v1/files), gets
// one topic as a PDF, holding the rows the box's operator may read in the
// browser (Q3 = OP): the topic door, then the per-message door, so a DM the
// operator is no end of is left out of a mixed topic. A topic the operator
// may not read answers exactly as a missing one: 404 not_found.

// Refusal tokens of the operator rule (spec 183 7.1.1); the render's come
// from topicpdf.Status. Not named Token*: gosec G101 reads a Token const as a
// credential (as CodePollNotAForm).
const (
	CodeOperatorAmbiguous = "operator_ambiguous"
	CodeTypedByNotBound   = "typed_by_not_bound"
)

func (s *Server) routeTopicExport(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/topics/{task_id}/export.pdf", s.handleTopicExport)
}

func (s *Server) handleTopicExport(w http.ResponseWriter, r *http.Request) {
	if !strings.HasPrefix(r.Header.Get("Authorization"), "Bearer ") {
		writeErr(w, http.StatusUnauthorized, "door", "a box upload token is required")
		return
	}
	t, box, ok := s.tokenTenant(w, r)
	if !ok {
		return
	}
	if box == WUIBox { // the browser's token is no principal here (mayReadFile)
		writeErr(w, http.StatusUnauthorized, "door", "a box upload token is required")
		return
	}
	ctx := r.Context()
	human, ie := s.topicExportOperator(ctx, t.ID, box, r.URL.Query().Get("typed_by"))
	if ie != nil {
		writeErr(w, ie.status, ie.token, ie.detail)
		return
	}
	task := r.PathValue("task_id")
	rows, err := s.topicExportRows(ctx, t.ID, task, human)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no such topic")
		return
	case err != nil:
		s.o.Log.Error().Err(err).Str("task_id", task).Msg("topic export read")
		writeErr(w, http.StatusInternalServerError, "internal", "topic export read failed")
		return
	}
	s.writeTopicPDF(w, r, t.ID, task, human, rows)
}

// topicExportOperator is the one human a box exports as, never the union of
// several (one person's DM would reach another): typed_by when it names a
// member bound to this box (rdb 0040), else 403 typed_by_not_bound; without
// it the box's single bound operator; several is 400 operator_ambiguous and
// none 404 not_found, as a topic the box may not read.
func (s *Server) topicExportOperator(ctx context.Context, tenant, box, typedBy string) (string, *issueErr) {
	ex, hasEx := s.o.Store.(store.TopicExports)
	ops, hasOps := s.o.Store.(store.BoxOperators)
	h, hasHumans := s.o.Store.(store.Humans)
	if !hasEx || !hasOps || !hasHumans {
		return "", &issueErr{http.StatusNotFound, "not_found", "no such topic"}
	}
	if typedBy != "" {
		if !humanIDRe.MatchString(typedBy) { // the raw value is never echoed
			return "", &issueErr{http.StatusForbidden, CodeTypedByNotBound, "typed_by is not a HUM id"}
		}
		notBound := &issueErr{http.StatusForbidden, CodeTypedByNotBound, typedBy + " is not bound as an operator of " + box}
		if _, err := h.MemberRole(ctx, typedBy, tenant); err != nil {
			return "", notBound
		}
		if bound, err := ops.BoxOperatorBound(ctx, tenant, box, typedBy); err != nil || !bound {
			return "", notBound
		}
		return typedBy, nil
	}
	hums, err := ex.BoxOperatorHumans(ctx, tenant, box)
	switch {
	case err != nil:
		return "", &issueErr{http.StatusInternalServerError, "internal", "operator lookup failed"}
	case len(hums) == 0:
		return "", &issueErr{http.StatusNotFound, "not_found", "no such topic"}
	case len(hums) > 1:
		return "", &issueErr{http.StatusBadRequest, CodeOperatorAmbiguous, box + " has several operators: name one with typed_by"}
	}
	return hums[0], nil
}

// topicExportRows is the OP read of spec 183 Q3, the one the render calls:
// the topic door (canReadTopic) for human, then the per-message door
// (canReadMessage) on every row, oldest first; in the demo workspace a
// moderator-hidden row is left out for a non-moderator (specs/077 T016).
// store.ErrNotFound for a missing topic and for one human may not read,
// alike; an empty human reads nothing (never canReadTopic's door-off "").
func (s *Server) topicExportRows(ctx context.Context, tenant, task, human string) ([]store.EditableMessage, error) {
	ex, ok := s.o.Store.(store.TopicExports)
	if human == "" || !ok {
		return nil, store.ErrNotFound
	}
	ctx, cancel := context.WithCancel(ctx) // the members memo lives while ctx does
	defer cancel()
	s.openMembersMemo(ctx)
	switch may, found, err := s.canReadTopic(ctx, tenant, task, human); {
	case err != nil:
		return nil, err
	case !found || !may:
		return nil, store.ErrNotFound
	}
	rows, err := ex.TopicExportRows(ctx, tenant, task, s.o.Now())
	if err != nil {
		return nil, err
	}
	mod, err := s.moderation(ctx, tenant, human) // specs/077 T016, as messageHidden
	if err != nil {
		return nil, err
	}
	out := make([]store.EditableMessage, 0, len(rows))
	for _, m := range rows {
		if mod.drops(m.MsgID) {
			continue
		}
		may, err := s.canReadMessage(ctx, tenant, m, human)
		if err != nil {
			return nil, err
		}
		if may {
			out = append(out, m)
		}
	}
	return out, nil
}

// topicExportLink is the topic's WUI permalink printed after each non-picture
// attachment (7.1.3), on the tenant's own WUI origin as topicLink builds it;
// "" when the hub has no tenant host pattern (lde, tests).
func (s *Server) topicExportLink(tenant, task string) string {
	origin := GcalWorkspaceURL(s.o.TenantHostPattern, s.o.WUIApexTenant, "")(tenant)
	if origin == "" {
		return ""
	}
	return origin + "/t/" + task
}

// renderRefusal is the detail of each topicpdf.Status token: the renderer's
// own words stay in the hub log.
var renderRefusal = map[string]string{
	"render_unavailable": "the PDF renderer is not configured, down or busy",
	"render_timeout":     "the PDF render ran past its wait",
	"too_large":          "the PDF is over " + strconv.Itoa(msg.MaxFileBytes) + " bytes",
}

// writeTopicPDF renders rows through topicpdf (7.1.5) and answers the PDF
// (7.1.1), or the refusal topicpdf.Status gives the render's error.
func (s *Server) writeTopicPDF(w http.ResponseWriter, r *http.Request, tenant, task, human string, rows []store.EditableMessage) {
	title := topicpdf.Title(rows)
	var opts []topicpdf.Option
	if link := s.topicExportLink(tenant, task); link != "" {
		opts = append(opts, topicpdf.WithTopicLink(link))
	}
	html, pictures, err := topicpdf.HTML(rows, title, s.topicExportBlob(r.Context(), tenant, human), opts...)
	if err != nil {
		s.o.Log.Error().Err(err).Str("task_id", task).Msg("topic export html")
		writeErr(w, http.StatusInternalServerError, "internal", "topic export html failed")
		return
	}
	var pdf []byte
	if s.o.TopicPDF == nil {
		err = topicpdf.ErrUnavailable
	} else {
		pdf, err = s.o.TopicPDF.Render(r.Context(), html)
	}
	if status, token := topicpdf.Status(err); err != nil {
		s.o.Log.Warn().Err(err).Str("task_id", task).Msg("topic export render")
		writeErr(w, status, token, renderRefusal[token])
		return
	}
	h := w.Header()
	h.Set("Content-Type", "application/pdf")
	h.Set("Content-Disposition", `attachment; filename="`+topicpdf.FileName(title, task, s.o.Now())+`"`)
	h.Set("X-Spool-Rows", strconv.Itoa(len(rows)))
	h.Set("X-Spool-Pictures", strconv.Itoa(pictures))
	h.Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	w.Write(pdf) //nolint:errcheck
}

// topicExportBlob fetches an attachment for the render as human reads it
// (fileReadableBy's human door): store.ErrNotFound for one human may not
// read or that is gone, bounded at msg.MaxFileBytes.
func (s *Server) topicExportBlob(ctx context.Context, tenant, human string) func(fileID string) ([]byte, error) {
	return func(fileID string) ([]byte, error) {
		switch may, err := s.fileReadableBy(ctx, tenant, fileID, "", human); {
		case err != nil:
			return nil, err
		case !may:
			return nil, store.ErrNotFound
		}
		key, err := blob.Key(tenant, fileID)
		if err != nil {
			return nil, store.ErrNotFound
		}
		rc, err := s.o.Blob.Get(ctx, key)
		if errors.Is(err, blob.ErrNotFound) {
			return nil, store.ErrNotFound
		}
		if err != nil {
			return nil, err
		}
		defer rc.Close()
		b, err := io.ReadAll(io.LimitReader(rc, msg.MaxFileBytes+1))
		if err == nil && len(b) > msg.MaxFileBytes {
			return nil, fmt.Errorf("file %s is over %d bytes", fileID, msg.MaxFileBytes)
		}
		return b, err
	}
}
