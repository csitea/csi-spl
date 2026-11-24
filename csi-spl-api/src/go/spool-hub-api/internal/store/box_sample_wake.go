package store

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"time"
)

// Spec 071 7.6.2 (SPL-6239 row T4): the refresh's NOTIFY channel. The hub
// instance that takes a click announces one request per asked box; every
// instance listens on the connection RunWake already holds and writes the
// box_sample frame when it holds that box's socket (row T5). Memory fans it
// out in process, as memWake does for the message wake-up, so the tests run
// two hub servers on one Memory store as two instances.

// BoxSampleChannel is the Postgres NOTIFY channel; the payload is
// "<tenant>|<box>|<req>|<deadline unix ms>".
const BoxSampleChannel = "spool_box_sample"

// BoxSampleReq is one announced request: ask (Tenant, Box) for a sample
// under ReqID, answered only until Deadline.
type BoxSampleReq struct {
	Tenant, Box, ReqID string
	Deadline           time.Time
}

// WakeHandlers are the listeners of the one listen connection; a nil one
// leaves its channel unlistened. None may block.
type WakeHandlers struct {
	Box       func(tenant, box string)   // WakeChannel
	WUI       func(tenant, msgID string) // WUIWakeChannel
	BoxSample func(BoxSampleReq)         // BoxSampleChannel
	// SigninRelay gets each spec 181 B11 relay event (SigninRelayChannel).
	SigninRelay func(payload string)
}

// BoxSampleWaker is implemented by stores that carry the refresh request.
type BoxSampleWaker interface {
	// AnnounceBoxSample tells every listener, this process's too, about r.
	AnnounceBoxSample(ctx context.Context, r BoxSampleReq) error
	// ListenAll is ListenWakes plus BoxSample, on the same connection,
	// until ctx ends (nil) or the connection fails (the error). A
	// malformed box sample payload is dropped, never delivered.
	ListenAll(ctx context.Context, h WakeHandlers) error
}

// ErrBoxSampleReq is a request that cannot be announced: an empty field, a
// field holding the separator, or no deadline.
var ErrBoxSampleReq = errors.New("box sample request: tenant, box and req must be set without '|', and a deadline")

// encodeBoxSample is the channel payload of r.
func encodeBoxSample(r BoxSampleReq) (string, error) {
	for _, f := range []string{r.Tenant, r.Box, r.ReqID} {
		if f == "" || strings.Contains(f, "|") {
			return "", ErrBoxSampleReq
		}
	}
	ms := r.Deadline.UnixMilli()
	if ms <= 0 {
		return "", ErrBoxSampleReq
	}
	return r.Tenant + "|" + r.Box + "|" + r.ReqID + "|" + strconv.FormatInt(ms, 10), nil
}

// decodeBoxSample parses a channel payload; ok false = malformed.
func decodeBoxSample(p string) (BoxSampleReq, bool) {
	f := strings.Split(p, "|")
	if len(f) != 4 || f[0] == "" || f[1] == "" || f[2] == "" {
		return BoxSampleReq{}, false
	}
	ms, err := strconv.ParseInt(f[3], 10, 64)
	if err != nil || ms <= 0 {
		return BoxSampleReq{}, false
	}
	return BoxSampleReq{Tenant: f[0], Box: f[1], ReqID: f[2], Deadline: time.UnixMilli(ms)}, true
}

// deliverBoxSample hands a payload to fn when it parses.
func deliverBoxSample(fn func(BoxSampleReq), payload string) {
	if r, ok := decodeBoxSample(payload); ok && fn != nil {
		fn(r)
	}
}

// notifyBoxSample fans a raw payload out to the in-process listeners; each
// parses it, as a Postgres listener parses the NOTIFY payload.
func (w *memWake) notifyBoxSample(payload string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	for _, sub := range w.subs {
		if sub.sample != nil {
			go deliverBoxSample(sub.sample, payload)
		}
	}
}

// AnnounceBoxSample fans r out to every in-process listener.
func (s *Memory) AnnounceBoxSample(_ context.Context, r BoxSampleReq) error {
	p, err := encodeBoxSample(r)
	if err != nil {
		return err
	}
	s.wake.notifyBoxSample(p)
	return nil
}

// AnnounceBoxSample sends the NOTIFY on a pooled connection: it reads no
// tenant table, so it needs no tenant scope.
func (s *Postgres) AnnounceBoxSample(ctx context.Context, r BoxSampleReq) error {
	p, err := encodeBoxSample(r)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `SELECT pg_notify('`+BoxSampleChannel+`', $1)`, p)
	return err
}
