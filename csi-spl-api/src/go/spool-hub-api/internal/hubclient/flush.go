package hubclient

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SendMessage delivers a composed v:1 message in hub mode (contracts/flush.md
// §1) and returns its delivery: local, sent, queued or pending (OQ-09).
//
//   - same box (to_box == this box): local inbox + outbox; the hub is skipped
//     unless mirror is on.
//   - cross box: outbox, then the signed envelope is written pending-flush
//     BEFORE the hub is tried, so a crash or an unreachable hub loses nothing.
func (c *Client) SendMessage(ctx context.Context, m *msg.Message, explicitToBox string) (string, error) {
	return c.SendMessageTyped(ctx, m, explicitToBox, "")
}

// SendMessageTyped is SendMessage with a typed_by claim on the send frame
// (specs/036 FR-009): the HUM-* who typed this line at the agent's terminal.
// It rides outside the signed envelope, is kept beside the pending file so a
// queued send still carries it, and the hub accepts it only against a
// box_operators binding (FR-010) - else typed_by_not_bound, a 4xx.
func (c *Client) SendMessageTyped(ctx context.Context, m *msg.Message, explicitToBox, typedBy string) (string, error) {
	return c.SendMessageClaims(ctx, m, explicitToBox, Claims{TypedBy: typedBy})
}

// SendMessageClaims is SendMessage with the send frame's claims (typed_by,
// ref_task_id) outside the signed envelope, kept beside the pending file.
func (c *Client) SendMessageClaims(ctx context.Context, m *msg.Message, explicitToBox string, cl Claims) (string, error) {
	if err := c.redactKeys(ctx, m); err != nil { // spec 127 L9: before any copy is written
		return "", err
	}
	own, priv, err := c.box()
	if err != nil {
		return "", err
	}
	st := spool.New(c.Cfg)
	toBox, err := c.ResolveToBox(m.To, explicitToBox)
	// specs/061 3.6: an id this box retired inside the quarantine, addressed
	// here (or announced by no other box), bounces to its sender as a reject.
	if (err == nil && toBox == own) || (err != nil && explicitToBox == "") {
		if berr := st.BounceRetired(m); berr != nil {
			return "", berr
		}
	}
	if err != nil {
		return "", err
	}
	mirror, err := c.Cfg.Mirror()
	if err != nil {
		return "", err
	}
	if toBox == own {
		if _, err := st.Deliver(m); err != nil {
			return "", err
		}
		if err := st.WriteOutbox(m); err != nil {
			return "", err
		}
		if !mirror {
			return wire.DeliveryLocal, nil
		}
	} else if err := st.WriteOutbox(m); err != nil {
		return "", err
	}

	env, err := wire.NewEnvelope(priv, own, toBox, m)
	if err != nil {
		return "", err
	}
	pending, err := c.writePending(m, env, cl)
	if err != nil {
		return "", err
	}
	delivery, err := c.sendNow(ctx, env, m, pending, cl)
	if toBox == own && err == nil {
		return wire.DeliveryLocal, nil // mirrored; the local copy is the delivery
	}
	return delivery, err
}

// SendAnswerMessage sends m as the answer to message answers (spec 068 4.2)
// from the seat that holds it on responsible_gen gen. Unlike SendMessage it
// is never queued: the hub's guard decides now, and a later flush would post
// it without the guard. A refusal is a 409 HubError (wire.TokenAnswered,
// wire.TokenNotResponsible); the outbox is written only once the hub took it.
func (c *Client) SendAnswerMessage(ctx context.Context, m *msg.Message, explicitToBox, answers string, gen int64) (string, error) {
	if err := c.redactKeys(ctx, m); err != nil { // spec 127 L9
		return "", err
	}
	own, priv, err := c.box()
	if err != nil {
		return "", err
	}
	toBox, err := c.ResolveToBox(m.To, explicitToBox)
	if err != nil {
		return "", err
	}
	env, err := wire.NewEnvelope(priv, own, toBox, m)
	if err != nil {
		return "", err
	}
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		return "", err
	}
	defer sess.Close()
	for _, a := range m.Files {
		if a.Mode == "blob" {
			if err := sess.UploadFile(ctx, a.FileID); err != nil {
				return "", err
			}
		}
	}
	f, err := sess.SendAnswer(ctx, env, answers, gen)
	var he *HubError
	if errors.As(err, &he) && he.Token == wire.TokenTopicMoved {
		f, err = c.answerMoved(ctx, env, m, he, answers, gen) // spec 169 T7b
	}
	if err != nil {
		return "", err
	}
	if err := spool.New(c.Cfg).WriteOutbox(m); err != nil {
		return "", err
	}
	return f.Delivery, nil
}

// SendChannelTyped posts m into channel (specs/038): the agent's broadcast,
// the same shape a human's post has - msg.to ALL-0, to_box box-wui (no box
// owns a channel post; the hub builds one delivery per member box and shows
// it in the channel feed), the channel tag signed into the envelope. Nothing
// is written to a local inbox: the sender does not read its own post, and the
// other members on THIS box receive it back from the hub like any member.
// Queued and flushed like any cross-box send.
func (c *Client) SendChannelTyped(ctx context.Context, m *msg.Message, channel, typedBy string) (string, error) {
	return c.SendChannelClaims(ctx, m, channel, Claims{TypedBy: typedBy})
}

// SendChannelClaims is SendChannelTyped with every send-frame claim.
func (c *Client) SendChannelClaims(ctx context.Context, m *msg.Message, channel string, cl Claims) (string, error) {
	own, priv, err := c.box()
	if err != nil {
		return "", err
	}
	if err := spool.New(c.Cfg).WriteOutbox(m); err != nil {
		return "", err
	}
	env, err := wire.NewEnvelopeIn(priv, own, wuiBox, channel, "", m)
	if err != nil {
		return "", err
	}
	pending, err := c.writePending(m, env, cl)
	if err != nil {
		return "", err
	}
	return c.sendNow(ctx, env, m, pending, cl)
}

// sendNow delivers one already-signed, already-pending envelope.
//
// specs/030 FP-2: it first offers the envelope to a LOCAL hub-run sidecar,
// which writes it on the warm hub session it already holds. That skips the
// cold dial this function used to pay every time - 220.6 ms p50 / 266.5 ms p95
// against the live dev hub (2026-09-21, n=20) - and the hub cannot tell the
// difference, because the bytes on the wire are the ones the CLI signed.
//
// Without a sidecar (or with SPOOL_SUBMIT_SOCKET=off) it falls through to the
// unchanged role=cli dial, so a box that runs no sidecar behaves exactly as it
// did before 030.
func (c *Client) sendNow(ctx context.Context, env *wire.Envelope, m *msg.Message, pending string, cl Claims) (string, error) {
	if len(m.Files) == 0 { // blobs need the REST upload a cli session carries
		raw, err := env.Marshal()
		if err != nil {
			return "", err
		}
		switch d, serr := c.submit(ctx, raw, cl); {
		case serr == nil:
			removePending(pending)
			return d, nil
		case errors.Is(serr, errNoSidecar):
			// no listener: fall through to the dial below
		case errors.Is(serr, ErrUnreachable):
			// The sidecar or its hub link is in trouble. The pending file is
			// already on disk, so the flush retries and the hub dedups on
			// msg_id: at-most-once delivery is preserved either way.
			return wire.DeliveryPending, nil
		default:
			var he *HubError
			if errors.As(serr, &he) && he.Token == wire.TokenTopicMoved {
				return c.movedRefused(ctx, env, m, pending, cl, he) // spec 169 T7b
			}
			if errors.As(serr, &he) && he.Status >= 500 {
				return wire.DeliveryPending, nil // as sendPending: retry on the next flush
			}
			if errors.As(serr, &he) && he.clientError() {
				c.reject(pending, serr) // a 4xx will never be accepted, whoever sends it
			}
			return "", serr
		}
	}
	sess, err := c.Dial(ctx, wire.RoleCLI)
	if errors.Is(err, ErrUnreachable) {
		return wire.DeliveryPending, nil
	}
	if err != nil {
		return "", err // e.g. an unpinned box: kept pending for a later flush
	}
	defer sess.Close()
	return sess.sendPending(ctx, env, m, pending, cl)
}

func (s *Session) sendPending(ctx context.Context, env *wire.Envelope, m *msg.Message, pending string, cl Claims) (string, error) {
	for _, a := range m.Files {
		if a.Mode != "blob" {
			continue
		}
		if err := s.UploadFile(ctx, a.FileID); err != nil {
			if errors.Is(err, ErrUnreachable) {
				return wire.DeliveryPending, nil
			}
			return "", err
		}
	}
	f, err := s.SendClaims(ctx, env, cl)
	var he *HubError
	switch {
	case errors.Is(err, ErrUnreachable):
		return wire.DeliveryPending, nil
	case s.role == wire.RoleCLI && errors.As(err, &he) && he.Token == wire.TokenFromNotAnnounced:
		// A cli session cannot announce. The box session's flush will: it
		// re-announces and resends, or rejects if the agent is not hosted.
		return wire.DeliveryPending, nil
	case errors.As(err, &he) && he.Token == wire.TokenTopicMoved && he.clientError(): // spec 169 T7b
		return s.c.movedRefused(ctx, env, m, pending, cl, he)
	case errors.As(err, &he) && he.clientError():
		s.c.reject(pending, err)
		return "", err
	case err != nil:
		return wire.DeliveryPending, nil // 5xx: retry on the next flush
	}
	removePending(pending)
	return f.Delivery, nil
}

// typedBySuffix names the file beside a pending envelope that holds its
// typed_by claim (specs/036 FR-009). The envelope file stays the exact signed
// bytes, so an older flusher still sends it (without the claim); Pending
// lists only *.json, so the sidecar is never mistaken for an envelope.
const typedBySuffix = ".typed_by"

// refTaskSuffix is typedBySuffix for the ref_task_id claim (spec 067 3.3).
const refTaskSuffix = ".ref_task_id"

// reroutedSuffix marks a pending envelope that is already the one re-route of a
// post to a moved topic (spec 169 T7b): it holds the workspace the post was
// refused in. Never on the frame: it only stops a second hop.
const reroutedSuffix = ".rerouted"

// claimSuffixes are the claim files a pending envelope may carry.
var claimSuffixes = []string{typedBySuffix, refTaskSuffix, reroutedSuffix}

// removePending drops a delivered pending envelope and its claim files.
func removePending(pending string) {
	if pending == "" {
		return
	}
	os.Remove(pending) //nolint:errcheck
	for _, sfx := range claimSuffixes {
		os.Remove(pending + sfx) //nolint:errcheck
	}
}

// pendingClaims reads a pending envelope's claims ("" each = none).
func pendingClaims(pending string) Claims {
	read := func(sfx string) string {
		b, err := os.ReadFile(pending + sfx)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}
	return Claims{TypedBy: read(typedBySuffix), RefTaskID: read(refTaskSuffix), Rerouted: read(reroutedSuffix)}
}

func (c *Client) pendingDir() string  { return filepath.Join(c.Cfg.HubDir(), "pending") }
func (c *Client) rejectedDir() string { return filepath.Join(c.Cfg.HubDir(), "rejected") }

// writePending stores the signed envelope as <ts>--<msg_id>.json (oldest-first
// by name). Flush sends these exact bytes: no re-sign, ts and to_box unchanged.
//
// Its claims (typed_by, ref_task_id) are written FIRST, beside it, so a flush
// that sees the envelope always sees its claims too.
func (c *Client) writePending(m *msg.Message, env *wire.Envelope, cl Claims) (string, error) {
	raw, err := env.Marshal()
	if err != nil {
		return "", err
	}
	stamp := strings.NewReplacer("-", "", ":", "").Replace(m.TS)
	p := filepath.Join(c.pendingDir(), stamp+"--"+m.MsgID+".json")
	for sfx, v := range map[string]string{typedBySuffix: cl.TypedBy, refTaskSuffix: cl.RefTaskID, reroutedSuffix: cl.Rerouted} {
		if v == "" {
			continue
		}
		if err := writeAtomic(p+sfx, []byte(v+"\n")); err != nil {
			return "", err
		}
	}
	return p, writeAtomic(p, raw)
}

// reasonSuffix names the file beside a rejected envelope that says why it was
// rejected (rejectReason as JSON). Like typedBySuffix it is not *.json, so
// nothing ever mistakes it for an envelope.
const reasonSuffix = ".reason"

// rejectReason is why an envelope left pending/ for good: the hub's refusal
// (Status + Token + Detail) or, with Status 0, a local one - an envelope this
// binary cannot parse or validate (Error).
type rejectReason struct {
	At     string `json:"at"`
	Status int    `json:"status,omitempty"`
	Token  string `json:"token,omitempty"`
	Detail string `json:"detail,omitempty"`
	Error  string `json:"error"`
}

// reject moves a pending envelope that will never be accepted to rejected/,
// and says why: one ERROR log line plus a <file>.reason beside it. A move
// without a reason is a message lost in silence: on prd 2026-10-02 two
// box-rsp -> c-002 sends sat in rejected/ with no trace, and the cause
// (a sidecar binary older than the c-NNN id grammar) had to be dug out of
// the binary itself.
func (c *Client) reject(pending string, why error) {
	if pending == "" {
		return
	}
	dst := filepath.Join(c.rejectedDir(), filepath.Base(pending))
	if err := os.MkdirAll(c.rejectedDir(), 0o775); err != nil {
		return
	}
	os.Rename(pending, dst) //nolint:errcheck
	for _, sfx := range claimSuffixes {
		os.Rename(pending+sfx, dst+sfx) //nolint:errcheck
	}
	r := rejectReason{At: time.Now().UTC().Format(time.RFC3339)}
	if why != nil {
		r.Error = why.Error()
	}
	var he *HubError
	if errors.As(why, &he) {
		r.Status, r.Token, r.Detail = he.Status, he.Token, he.Detail
	}
	if raw, err := json.Marshal(r); err == nil {
		writeAtomic(dst+reasonSuffix, append(raw, '\n')) //nolint:errcheck
	}
	c.Log.Error().Str("box", c.Cfg.BoxID).Str("file", dst).Int("status", r.Status).
		Str("token", r.Token).Str("detail", r.Detail).Str("error", r.Error).
		Msg("moved a pending envelope to rejected/: it will never be delivered")
}

// Pending lists the pending-flush envelope files, oldest first.
func (c *Client) Pending() ([]string, error) {
	ents, err := os.ReadDir(c.pendingDir())
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var out []string
	for _, e := range ents {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".json") {
			out = append(out, filepath.Join(c.pendingDir(), e.Name()))
		}
	}
	sort.Strings(out)
	return out, nil
}

// Flush sends every pending envelope on s (contracts/flush.md §2). It stops at
// the first refusal (moved to rejected/, returned: exit 78 for verify-class)
// or when the hub drops (the rest stay pending). Its result is recorded for
// `spool hub-queue` (queue_health.go).
func (s *Session) Flush(ctx context.Context) (int, error) {
	n, err := s.flush(ctx)
	s.c.recordFlush(n, err)
	return n, err
}

func (s *Session) flush(ctx context.Context) (int, error) {
	list, err := s.c.Pending()
	if err != nil {
		return 0, err
	}
	n := 0
	for _, p := range list {
		raw, err := os.ReadFile(p)
		if err != nil {
			return n, err
		}
		env, err := wire.ParseEnvelope(raw)
		if err != nil {
			s.c.reject(p, err)
			return n, fmt.Errorf("pending %s: %w", filepath.Base(p), err)
		}
		m, err := env.Inner()
		if err != nil {
			s.c.reject(p, err)
			return n, fmt.Errorf("pending %s: %w", filepath.Base(p), err)
		}
		d, err := s.sendPending(ctx, env, m, p, pendingClaims(p))
		if err != nil {
			return n, err
		}
		if d == wire.DeliveryPending {
			return n, fmt.Errorf("%w: flush interrupted", ErrUnreachable)
		}
		n++
	}
	r, err := s.flushRecords(ctx) // spec 058 section 7, record.go
	return n + r, err
}

// SyncReport is what a one-shot hub-sync did.
type SyncReport struct {
	Delivered int `json:"delivered"`
	Flushed   int `json:"flushed"`
	Pending   int `json:"pending"`
	Refused   int `json:"refused"`
}

// Sync is one role=box session: hello, pin sync, drain the hub queue, flush
// pending, close. A refused recv frame (e.g. unsynced sender pin) is returned
// as the error after the rest has run. SyncReport.Pending is the outbox left
// after the flush, or -1 (logged) when the outbox cannot be scanned, so an
// unreadable outbox never reads as "nothing pending".
func (c *Client) Sync(ctx context.Context) (SyncReport, error) {
	var r SyncReport
	sess, err := c.Dial(ctx, wire.RoleBox)
	if err != nil {
		return r, err
	}
	defer sess.Close()
	if _, err := sess.WaitQueueEnd(ctx); err != nil {
		return r, err
	}
	r.Flushed, err = sess.Flush(ctx)
	r.Pending = c.pendingCount()
	r.Delivered = sess.Delivered()
	rerrs := sess.RecvErrors()
	r.Refused = len(rerrs)
	if err != nil {
		return r, err
	}
	if len(rerrs) > 0 {
		return r, rerrs[0]
	}
	// hub-sync still reports a pin it refused to overwrite. Run does not:
	// Dial has already kept the session.
	if sess.pinConflict != nil {
		return r, sess.pinConflict
	}
	return r, nil
}

// pendingCount is len(Pending()), or -1 with a warning when the outbox scan
// fails.
func (c *Client) pendingCount() int {
	left, err := c.Pending()
	if err != nil {
		c.Log.Warn().Err(err).Str("box", c.Cfg.BoxID).Msg("outbox scan; pending unknown")
		return -1
	}
	return len(left)
}

// Run is the box daemon (`spool hub-run`): it holds the role=box session,
// reconnecting with capped exponential backoff and equal jitter (1 s ceiling
// doubling to a 60 s cap, each wait in [ceiling/2, ceiling], one upgrade per
// attempt; a Retry-After on the refused upgrade is honoured, see backoff.go)
// on any close, re-helloing, flushing, logging the fallback queue every
// QueueLogEvery (SPL-2165), refreshing pins on an
// interval and re-announcing the roster when the $SPOOL_ROOT/*/ scan changes
// (OQ-05). The backoff resets only after a session stayed up for stableAfter,
// so a hub that accepts and drops at once is not hammered every second. It
// returns when ctx ends, or ErrSuperseded when another hub-run holds the box:
// a newer hello first makes it yield and say hello again (supersede.go).
//
// The submit listener is opened once, for the life of Run, and handed each
// session in turn; hold swaps sessions make-before-break and a planned 1012
// close of a stable session is redialled at once (SPL-6514, rotate.go).
func (c *Client) Run(ctx context.Context) error {
	wctx, stopWatch := context.WithCancel(ctx)
	defer stopWatch()
	go c.watchQueue(wctx) // up or down: a down hub is when the queue grows
	srv, stopSubmit := c.serveSubmit(ctx)
	defer stopSubmit()
	b := newBackoff(runBackoffBase, runBackoffMax, runBackoffMax)
	b.half = true
	rehello := false // the session held is the re-hello after a 4409
	for {
		var retryAfter time.Duration
		planned := false
		sess, err := c.dial(ctx, wire.RoleBox, 0)
		if err == nil {
			c.Log.Info().Str("box", c.Cfg.BoxID).Msg("hub session up")
			up := time.Now()
			var herr error
			planned, herr = c.holdLink(ctx, sess, srv)
			if errors.Is(herr, ErrSuperseded) && ctx.Err() == nil {
				if c.yield(ctx, &rehello, time.Since(up)) {
					return herr
				}
				continue
			}
			if herr != nil {
				return herr
			}
			rehello = false
			if time.Since(up) >= stableAfter {
				b.reset()
			}
			if time.Since(up) < plannedMinUp {
				planned = false // a hub that closes at once is backed off, 1012 or not
			}
		} else {
			retryAfter = retryAfterOf(err)
		}
		if ctx.Err() != nil {
			return nil
		}
		if planned {
			c.Log.Info().Str("box", c.Cfg.BoxID).Msg("hub closed the session at its max life; redialling at once")
			continue
		}
		sleep := b.next(retryAfter)
		if err != nil {
			c.Log.Warn().Err(err).Dur("retry_in", sleep).Msg("hub session down")
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(sleep):
		}
	}
}

// rosterScanEvery is how often hold re-reads the run report to re-announce a
// changed one.
const rosterScanEvery = 10 * time.Second

// hold serves one session until it ends, without a submit listener. It
// returns ErrSuperseded on 4409 and nil for every other close.
func (c *Client) hold(ctx context.Context, sess *Session) error {
	_, err := c.holdLink(ctx, sess, nil)
	return err
}

// holdLink serves sess, and every session a rotation swaps in after it,
// until the session held ends. It returns ErrSuperseded on 4409 and nil for
// every other close (the caller reconnects); planned is a 1012 max-life
// close by the hub.
func (c *Client) holdLink(ctx context.Context, sess *Session, srv *SubmitServer) (bool, error) {
	for {
		srv.set(sess)
		next, planned, err := c.holdOne(ctx, sess, srv)
		if next == nil {
			return planned, err
		}
		sess = next
	}
}

// holdOne serves one session. It returns the next session when a rotation
// swapped one in (the old one is then closing already), else nil with
// holdLink's results.
//
// Everything it does runs under hctx, which ends with the session as well as
// with ctx: a session that keepalive has declared dead cancels the pin
// refresh, probe or flush in flight, and holdOne returns at once. Before,
// those REST calls ran under the daemon's never-ending ctx, so one that hit a
// silent hub kept hold parked for ever on a session already closed - the
// process up, the box deaf (prd t1 desk, 2026-10-03 11:36Z, 16 min).
func (c *Client) holdOne(ctx context.Context, sess *Session, srv *SubmitServer) (next *Session, planned bool, err error) {
	daemon := ctx
	defer func() {
		if next == nil {
			sess.Close()
		}
	}()
	hctx, stop := context.WithCancel(ctx)
	defer stop()
	defer context.AfterFunc(sess.ctx, stop)()
	ctx = hctx
	if _, err := sess.Flush(ctx); err != nil {
		c.Log.Warn().Err(err).Msg("flush")
	}
	t := c.holdTickers()
	defer t.stop()
	var rotateFailed time.Time // the last failed rotation dial (ended)
	for {
		select {
		case <-ctx.Done():
			select {
			case <-sess.Done(): // the read loop ended: was it a 4409?
				return c.ended(sess, rotateFailed)
			default:
				return nil, false, nil
			}
		case <-sess.Done():
			return c.ended(sess, rotateFailed)
		case <-t.rotate:
			if next := c.rotate(daemon, sess, srv); next != nil {
				return next, false, nil
			}
			rotateFailed = time.Now()
			t.rotateT.Reset(rotateRetry)
		case <-srv.Kick():
			if left, _ := c.Pending(); len(left) > 0 {
				sess.Flush(ctx) //nolint:errcheck
			}
		case <-t.pins:
			if err := sess.SyncPins(ctx); err != nil {
				if c.stranded("pin refresh", err) {
					return nil, false, nil
				}
				c.Log.Warn().Err(err).Msg("pin refresh")
			}
		case <-t.probe:
			if err := sess.Probe(ctx); err != nil {
				if c.stranded("session probe", err) {
					return nil, false, nil
				}
				c.Log.Debug().Err(err).Msg("session probe")
			}
		case <-t.scan:
			c.scanTick(ctx, sess, &t.roster)
		}
	}
}

// holdTickers are holdOne's periodic wake-ups; a nil channel never fires.
type holdTickers struct {
	pins, probe, scan, rotate <-chan time.Time
	rotateT                   *time.Timer
	roster                    string
	stops                     []func()
}

func (c *Client) holdTickers() *holdTickers {
	t := &holdTickers{}
	t.roster, _ = c.rosterKey()
	pins := time.NewTicker(c.PinRefresh)
	scan := time.NewTicker(rosterScanEvery)
	t.pins, t.scan = pins.C, scan.C
	t.stops = append(t.stops, pins.Stop, scan.Stop)
	if every := c.SessionProbe; every >= 0 {
		if every == 0 {
			every = defaultSessionProbe
		}
		probe := time.NewTicker(every)
		t.probe = probe.C
		t.stops = append(t.stops, probe.Stop)
	}
	if rt, ch := c.rotateTimer(); rt != nil {
		t.rotateT, t.rotate = rt, ch
		t.stops = append(t.stops, func() { rt.Stop() })
	}
	return t
}

func (t *holdTickers) stop() {
	for _, f := range t.stops {
		f()
	}
}

// scanTick re-announces a changed run report (t1 bc1a43e1) and flushes what
// is pending: the backstop of the flush kicks, for a pending file no submit
// told the listener about, and the only flush of a queued record-only copy
// (spec 058 section 7), which never goes through the submit socket.
func (c *Client) scanTick(ctx context.Context, sess *Session, last *string) {
	if k, ok := c.rosterKey(); ok && k != *last {
		*last = k
		sess.Announce(ctx) //nolint:errcheck
	}
	if c.queued(sess.takesRecords()) {
		sess.Flush(ctx) //nolint:errcheck
	}
}

// stranded logs why a session is being given up and returns true when err
// proves the socket belongs to a hub process that no longer serves REST (see
// Client.SessionProbe). holdOne then returns, its deferred Close ends the
// socket, and Run redials - onto the process that does serve, whose hello
// drains everything queued for this box meanwhile.
//
// With rotation on (SPL-6514, rotate.go) a door is never proof: during a
// hub roll the door comes from the OTHER live revision while the socket's
// own still pongs and delivers. The session is kept, and the next rotation
// moves it.
func (c *Client) stranded(what string, err error) bool {
	if !orphaned(err) {
		return false
	}
	if c.rotates() {
		c.Log.Info().Err(err).Str("check", what).
			Msg("another hub revision refused this session's token; the socket still answers, so it stays until the next rotation")
		return false
	}
	c.Log.Warn().Err(err).Str("check", what).
		Msg("hub no longer knows this session (a hub redeploy or restart); closing it so the session reconnects")
	return true
}

// queued reports a pending envelope, or, when records is set (a session
// whose hub takes records), a queued record-only copy (spec 058 section 7)
// for the next flush. On a hub without the feature the record queue is not
// read, so a waiting record fires no flush every 10 s.
func (c *Client) queued(records bool) bool {
	if left, _ := c.Pending(); len(left) > 0 {
		return true
	}
	if !records {
		return false
	}
	recs, _ := c.Records()
	return len(recs) > 0
}

// serveSubmit opens the box-local submit socket for as long as ctx lives,
// and returns it (nil when not opened) with the func that closes it. A
// listener that will not open is not fatal: the box keeps working, every
// send just pays the dial. Run hands it each session (SubmitServer.set).
func (c *Client) serveSubmit(ctx context.Context) (*SubmitServer, func()) {
	sctx, stopSubmit := context.WithCancel(ctx)
	srv, err := c.Listen()
	if err != nil {
		c.Log.Warn().Err(err).Str("socket", c.Cfg.SubmitPath()).Msg("submit listener not opened; sends will dial")
	}
	if srv == nil {
		return nil, stopSubmit
	}
	go srv.Serve(sctx, nil)
	c.Log.Info().Str("socket", c.Cfg.SubmitPath()).Msg("submit listener up")
	return srv, func() { stopSubmit(); srv.Close() }
}

// endErr is what hold returns for a session whose read loop has ended:
// ErrSuperseded on 4409 (a newer hello took the box), else nil (redial).
func (s *Session) endErr() error {
	if s.CloseCode() == wire.CloseSuperseded {
		return ErrSuperseded
	}
	return nil
}
