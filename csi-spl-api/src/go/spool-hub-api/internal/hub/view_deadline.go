package hub

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The view deadline (SPL-2866, the prd incident of 2026-10-22): /v1/view/*
// requests took 100..164 s and then answered 500, while each held one of the
// instance's few pool connections (cnf SPOOL_HUB_DB_MAX_CONNS) or queued for
// one; sign-in, queued behind them, gave up at its own 10 s with a 503 while
// Postgres had free connections. A view request now has a hard limit,
// Options.ViewTimeout (cnf SPOOL_HUB_VIEW_TIMEOUT):
//
//   - each statement it runs carries statement_timeout = the limit
//     (store.WithStatementTimeout): Postgres cancels it and the connection
//     goes back to the pool whole;
//   - its context ends viewDeadlineGrace later: that bounds the pool wait and
//     a request of many statements, and frees its connection either way;
//   - a 5xx the handler answers once the limit has passed becomes
//     503 view_timeout, which says what happened, in place of a bare 500.
//
// OPTIONS and an upgrade are not views and pass untouched.

// viewDeadlineGrace is how much longer the request's context lives than its
// statement budget, so a single slow statement is cancelled by Postgres
// (connection kept) before the context closes the connection under it; the
// same +1 s as search's own budget (search.go).
const viewDeadlineGrace = time.Second

// viewTimeoutToken is the error token of a view cut at its limit.
const viewTimeoutToken = "view_timeout"

func (s *Server) viewDeadline(next http.Handler) http.Handler {
	limit := s.o.ViewTimeout
	if limit <= 0 {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions || !strings.HasPrefix(r.URL.Path, etagPrefix) || r.Header.Get("Upgrade") != "" {
			next.ServeHTTP(w, r)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), limit+viewDeadlineGrace)
		defer cancel()
		ctx = store.WithStatementTimeout(ctx, limit)
		vw := &viewDeadlineWriter{ResponseWriter: w, ctx: ctx, start: time.Now(), limit: limit}
		next.ServeHTTP(vw, r.WithContext(ctx))
	})
}

// viewDeadlineWriter turns a 5xx answered past the limit into 503
// view_timeout. The handler's own cause is still the one the ERROR line
// logs: writeErr notes it (noteCause, through Unwrap) before its header.
type viewDeadlineWriter struct {
	http.ResponseWriter
	ctx      context.Context
	start    time.Time
	limit    time.Duration
	wrote    bool
	timedOut bool
}

func (v *viewDeadlineWriter) WriteHeader(code int) {
	if v.wrote {
		return
	}
	v.wrote = true
	if code >= 500 && v.pastLimit() {
		v.timedOut = true
		v.Header().Del("Content-Length")
		wire.WriteError(v.ResponseWriter, http.StatusServiceUnavailable, viewTimeoutToken,
			fmt.Sprintf("the view ran past its %s limit; try again", v.limit))
		return
	}
	v.ResponseWriter.WriteHeader(code)
}

// pastLimit: the context's deadline fired, or the request has run its limit
// (a statement Postgres cancelled at statement_timeout ends before it).
func (v *viewDeadlineWriter) pastLimit() bool {
	return errors.Is(v.ctx.Err(), context.DeadlineExceeded) || time.Since(v.start) >= v.limit
}

func (v *viewDeadlineWriter) Write(b []byte) (int, error) {
	if !v.wrote {
		v.WriteHeader(http.StatusOK)
	}
	if v.timedOut {
		return len(b), nil // the handler's error body; view_timeout is sent
	}
	return v.ResponseWriter.Write(b)
}

func (v *viewDeadlineWriter) Flush() {
	if f, ok := v.ResponseWriter.(http.Flusher); ok && !v.timedOut {
		f.Flush()
	}
}

func (v *viewDeadlineWriter) Unwrap() http.ResponseWriter { return v.ResponseWriter }
