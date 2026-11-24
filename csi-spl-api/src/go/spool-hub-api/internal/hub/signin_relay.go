package hub

import (
	"bytes"
	"cmp"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"filippo.io/age"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The web-UI sign-in relay (spec 181 row B11, gap G11; owner Q-5, Q-14 A;
// spec 159 4.3). A biz owner or admin of a workspace signs a CLI on the
// workspace's private VM in to their own subscription, from the web UI
// only: the hub relays the vendor URL the CLI's terminal login prints out
// to the person, and the code they paste back in to that login.
//
//	POST   /v1/signin-relay                {"kind", "box"?} -> 201 {"relay","kind","box","state","expires_at"}
//	GET    /v1/signin-relay/{relay}        -> 200 {"relay","kind","box","state","url"?,"reason"?,"expires_at"}
//	POST   /v1/signin-relay/{relay}/input  {"input"} -> 202 {"relay","state":"input_sent"}
//	DELETE /v1/signin-relay/{relay}        -> 204
//
// One switch per vendor, default off: hub env SPOOL_HUB_SIGNIN_RELAY_KINDS
// (Options.SigninRelayKinds) names the kinds whose vendor gave its written
// OK (O1 Anthropic, O2 xAI, O3 Mistral). A kind it does not name is 403
// signin_relay_off, before anything is announced or sent.
//
// Who: a member with vendor_keys.manage (biz owner, admin), never under an
// act-as session; only the person who started a relay reads or feeds it.
// Where: the workspace's dedicated box (its private VM, 108 3.8) whose pin
// holds a desk recipient (rdb 0235).
//
// Nothing is stored (Q-14 A): no table, no row, no log line holds the
// input. The relay's state lives in each hub instance's memory until its
// deadline, fed by store.SigninRelayChannel events; the input is sealed
// with age to the VM's desk recipient inside the input handler, so the
// event, the frame and every log carry only ciphertext. The URL the VM
// reports is kept in memory for the person's poll and never logged.

// signinRelayTTL is how long a relay lives; the CLI's own login times out
// on its side too.
const signinRelayTTL = 10 * time.Minute

// signinRelayInputMax caps one input (a vendor code is far shorter).
const signinRelayInputMax = 512

// signinRelayURLMax caps the vendor URL a box may report.
const signinRelayURLMax = 2048

// The states the hub itself sets, beside the box's wire.SigninState*.
const (
	signinStateStarting  = "starting"
	signinStateInputSent = "input_sent"
)

// relayEvent is one announced event (store.SigninRelayChannel): start,
// input and end from a web-UI request, out from the VM's report.
type relayEvent struct {
	Op       string `json:"op"`
	Relay    string `json:"relay"`
	Tenant   string `json:"tenant"`
	Box      string `json:"box"`
	Kind     string `json:"kind,omitempty"`
	By       string `json:"by,omitempty"`
	Deadline int64  `json:"deadline,omitempty"` // unix ms, start only
	Frame    string `json:"frame,omitempty"`    // start / input / end: the frame id
	Sealed   string `json:"sealed,omitempty"`   // input only: ciphertext
	State    string `json:"state,omitempty"`    // out only
	URL      string `json:"url,omitempty"`      // out only
	Reason   string `json:"reason,omitempty"`   // out only
}

// relayOpOut is the event op of a box's report.
const relayOpOut = "out"

// signinRelay is one relay as this instance knows it.
type signinRelay struct {
	tenant, box, kind, by string
	deadline              time.Time
	state, url, reason    string
	frames                []*relayFrame
}

// relayFrame is one frame for the VM, written at most once by this instance.
type relayFrame struct {
	lane    wire.SigninRelayLane
	written bool
}

// signinRelays is this instance's relay map; its own lock.
type signinRelays struct {
	mu sync.Mutex
	m  map[string]*signinRelay
}

// apply folds one event in and drops every relay past its deadline. It
// reports whether the event left a frame to write to the VM.
func (p *signinRelays) apply(ev relayEvent, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.m == nil {
		p.m = map[string]*signinRelay{}
	}
	for k, v := range p.m {
		if now.After(v.deadline) {
			delete(p.m, k)
		}
	}
	r := p.m[ev.Relay]
	if ev.Op == wire.SigninOpStart && r == nil {
		r = &signinRelay{tenant: ev.Tenant, box: ev.Box, kind: ev.Kind, by: ev.By,
			deadline: time.UnixMilli(ev.Deadline), state: signinStateStarting}
		if now.After(r.deadline) {
			return false
		}
		p.m[ev.Relay] = r
	}
	if r == nil || r.tenant != ev.Tenant || r.box != ev.Box {
		return false
	}
	return r.fold(ev)
}

// fold applies ev to r; true when it queued a frame.
func (r *signinRelay) fold(ev relayEvent) bool {
	if ev.Op == relayOpOut {
		r.state, r.url, r.reason = ev.State, cmp.Or(ev.URL, r.url), ev.Reason
		return false
	}
	lane := wire.SigninRelayLane{ID: ev.Frame, Op: ev.Op, Kind: r.kind, Sealed: ev.Sealed}
	if ev.Frame == "" || slices.ContainsFunc(r.frames, func(f *relayFrame) bool { return f.lane.ID == ev.Frame }) {
		return false
	}
	r.frames = append(r.frames, &relayFrame{lane: lane})
	switch ev.Op {
	case wire.SigninOpInput:
		r.state = signinStateInputSent
	case wire.SigninOpEnd:
		r.state = wire.SigninStateEnded
	}
	return true
}

// claim returns the frames of (tenant, box)'s live relays this instance
// has not written yet, marked written, each with its relay id.
func (p *signinRelays) claim(tenant, box string, now time.Time) (relays []string, lanes []wire.SigninRelayLane) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for id, r := range p.m {
		if r.tenant != tenant || r.box != box || now.After(r.deadline) {
			continue
		}
		for _, f := range r.frames {
			if !f.written {
				f.written = true
				relays, lanes = append(relays, id), append(lanes, f.lane)
			}
		}
	}
	return relays, lanes
}

// signinRelayView is what a GET answers; never the input.
type signinRelayView struct {
	Relay     string `json:"relay"`
	Kind      string `json:"kind"`
	Box       string `json:"box"`
	State     string `json:"state"`
	URL       string `json:"url,omitempty"`
	Reason    string `json:"reason,omitempty"`
	ExpiresAt string `json:"expires_at"`
}

// view is relay id's view for its starter in tenant; false = no such live
// relay for them.
func (p *signinRelays) view(id, tenant, by string, now time.Time) (signinRelayView, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	r := p.m[id]
	if r == nil || r.tenant != tenant || r.by != by || now.After(r.deadline) {
		return signinRelayView{}, false
	}
	return signinRelayView{Relay: id, Kind: r.kind, Box: r.box, State: r.state, URL: r.url, Reason: r.reason,
		ExpiresAt: r.deadline.UTC().Format(time.RFC3339)}, true
}

// live reports whether relay id lives on (tenant, box).
func (p *signinRelays) live(id, tenant, box string, now time.Time) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	r := p.m[id]
	return r != nil && r.tenant == tenant && r.box == box && !now.After(r.deadline)
}

func (s *Server) routeSigninRelay(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/signin-relay", s.handleSigninRelayStart)
	mux.HandleFunc("GET /v1/signin-relay/{relay}", s.handleSigninRelayGet)
	mux.HandleFunc("POST /v1/signin-relay/{relay}/input", s.handleSigninRelayInput)
	mux.HandleFunc("DELETE /v1/signin-relay/{relay}", s.handleSigninRelayEnd)
	mux.HandleFunc("OPTIONS /v1/signin-relay", s.vendorKeysPreflight)
	mux.HandleFunc("OPTIONS /v1/signin-relay/{relay}", s.vendorKeysPreflight)
	mux.HandleFunc("OPTIONS /v1/signin-relay/{relay}/input", s.vendorKeysPreflight)
}

// signinRelayActor is the caller: a member who manages the workspace's
// vendor keys, not under act-as, on a hub whose store carries the relay.
func (s *Server) signinRelayActor(w http.ResponseWriter, r *http.Request) (tenant, hum string, wk store.SigninRelayWaker, ok bool) {
	t, a, _, _, ok := s.membersActor(w, r, rbac.VendorKeysManage)
	if !ok {
		return "", "", nil, false
	}
	if s.vendorKeyActAs(r.Context(), t.ID, a.HumanID) {
		writeErr(w, http.StatusForbidden, "act_as_refused", "a subscription is never signed in under an act-as session")
		return "", "", nil, false
	}
	wk, ok = s.o.Store.(store.SigninRelayWaker)
	if !ok {
		writeErr(w, http.StatusServiceUnavailable, "signin_relay_unavailable", "this hub's store carries no sign-in relay")
		return "", "", nil, false
	}
	return t.ID, a.HumanID, wk, true
}

// signinRelayKindOn checks kind and its switch: 400 bad_kind, 403
// signin_relay_off.
func (s *Server) signinRelayKindOn(w http.ResponseWriter, kind string) bool {
	if !slices.Contains(store.VendorKeyKinds, kind) {
		writeErr(w, http.StatusBadRequest, "bad_kind", "not a vendor kind")
		return false
	}
	if !slices.Contains(s.o.SigninRelayKinds, kind) {
		writeErr(w, http.StatusForbidden, "signin_relay_off",
			"the sign-in relay is off for this vendor: it is switched on only after the vendor's written OK; an API key on Agent keys works meanwhile")
		return false
	}
	return true
}

// decodeSmall strictly decodes a small JSON body into v.
func decodeSmall(r *http.Request, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 4096))
	dec.DisallowUnknownFields()
	return dec.Decode(v)
}

func (s *Server) handleSigninRelayStart(w http.ResponseWriter, r *http.Request) {
	tenant, hum, wk, ok := s.signinRelayActor(w, r)
	if !ok {
		return
	}
	var in struct {
		Kind string `json:"kind"`
		Box  string `json:"box,omitempty"`
	}
	if decodeSmall(r, &in) != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", `want {"kind", "box"?}`)
		return
	}
	if !s.signinRelayKindOn(w, in.Kind) {
		return
	}
	box, _, ok := s.signinRelayBox(w, r.Context(), tenant, in.Box)
	if !ok {
		return
	}
	now := s.o.Now()
	ev := relayEvent{Op: wire.SigninOpStart, Relay: uid.New(), Tenant: tenant, Box: box, Kind: in.Kind, By: hum,
		Deadline: now.Add(signinRelayTTL).UnixMilli(), Frame: uid.New()}
	if !s.announceSigninRelay(w, r.Context(), wk, ev) {
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("box", box).Str("kind", in.Kind).Str("relay", ev.Relay).Str("by", hum).
		Msg("signin_relay.start")
	writeJSON(w, http.StatusCreated, signinRelayView{Relay: ev.Relay, Kind: in.Kind, Box: box, State: signinStateStarting,
		ExpiresAt: time.UnixMilli(ev.Deadline).UTC().Format(time.RFC3339)})
}

// signinRelayBox is the workspace's private VM: its dedicated box (the one
// named, else the only one) and that pin's desk recipient. 409
// no_private_vm, box_required, box_key_not_enrolled.
func (s *Server) signinRelayBox(w http.ResponseWriter, ctx context.Context, tenant, want string) (string, age.Recipient, bool) {
	boxes, err := s.dedicatedBoxes(ctx, tenant)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", "the workspace's boxes were not read")
		return "", nil, false
	}
	box := want
	switch {
	case want != "" && !slices.Contains(boxes, want), len(boxes) == 0:
		writeErr(w, http.StatusConflict, "no_private_vm", "this workspace has no such dedicated box (its private VM) to sign in on")
		return "", nil, false
	case want == "" && len(boxes) > 1:
		writeErr(w, http.StatusConflict, "box_required", "this workspace has several dedicated boxes: name one")
		return "", nil, false
	case want == "":
		box = boxes[0]
	}
	to, ok := s.deskRecipient(ctx, tenant, box)
	if !ok {
		writeErr(w, http.StatusConflict, "box_key_not_enrolled", "this box registered no X25519 key at join, so nothing can be sealed to it")
		return "", nil, false
	}
	return box, to, true
}

// dedicatedBoxes are tenant's pinned boxes that joined as dedicated.
func (s *Server) dedicatedBoxes(ctx context.Context, tenant string) ([]string, error) {
	pm, ok := s.o.Store.(store.BoxJoinSwitch)
	if !ok {
		return nil, nil
	}
	pins, err := s.o.Store.ListPins(ctx, tenant)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, p := range pins {
		mode, err := pm.PinBoxMode(ctx, tenant, p.BoxID)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			return nil, err
		}
		if mode == store.BoxModeDedicated {
			out = append(out, p.BoxID)
		}
	}
	slices.Sort(out)
	return out, nil
}

// deskRecipient is box's desk X25519 recipient (rdb 0235).
func (s *Server) deskRecipient(ctx context.Context, tenant, box string) (age.Recipient, bool) {
	px, ok := s.o.Store.(store.PinX25519)
	if !ok {
		return nil, false
	}
	rcpt, err := px.PinBoxX25519(ctx, tenant, box)
	if err != nil || rcpt == "" {
		return nil, false
	}
	to, err := age.ParseX25519Recipient(rcpt)
	return to, err == nil
}

// announceSigninRelay sends ev to every instance; 503 when it fails.
func (s *Server) announceSigninRelay(w http.ResponseWriter, ctx context.Context, wk store.SigninRelayWaker, ev relayEvent) bool {
	if err := s.announceRelay(ctx, wk, ev); err != nil {
		writeErr(w, http.StatusServiceUnavailable, "signin_relay_unavailable", "the relay could not reach the hub's instances")
		return false
	}
	return true
}

// announceRelay sends ev to every instance, then folds it in here at once,
// so the caller's next read sees it before the listener echoes it back (a
// repeat is a no-op: frames are keyed by id). The error is logged by op
// only: an input event's text is ciphertext, and still never logged.
func (s *Server) announceRelay(ctx context.Context, wk store.SigninRelayWaker, ev relayEvent) error {
	raw, err := json.Marshal(ev)
	if err == nil {
		err = wk.AnnounceSigninRelay(ctx, string(raw))
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", ev.Tenant).Str("relay", ev.Relay).Str("op", ev.Op).Msg("signin_relay.announce_failed")
		return err
	}
	s.foldRelay(ev)
	return nil
}

// foldRelay folds ev into this instance's map and writes its frame when
// this instance holds the VM's socket.
func (s *Server) foldRelay(ev relayEvent) {
	if !s.relays.apply(ev, s.o.Now()) {
		return
	}
	if x := s.heldBox(ev.Tenant, ev.Box); x != nil {
		go s.sendSigninRelay(context.Background(), x)
	}
}

// signinRelayOwn is the caller's live relay from the path: 404 not_found
// for any other (another person's, another workspace's, an expired one).
func (s *Server) signinRelayOwn(w http.ResponseWriter, r *http.Request) (signinRelayView, string, store.SigninRelayWaker, bool) {
	tenant, hum, wk, ok := s.signinRelayActor(w, r)
	if !ok {
		return signinRelayView{}, "", nil, false
	}
	v, ok := s.relays.view(r.PathValue("relay"), tenant, hum, s.o.Now())
	if !ok {
		writeErr(w, http.StatusNotFound, "not_found", "no such sign-in relay of yours")
		return signinRelayView{}, "", nil, false
	}
	return v, tenant, wk, true
}

func (s *Server) handleSigninRelayGet(w http.ResponseWriter, r *http.Request) {
	v, _, _, ok := s.signinRelayOwn(w, r)
	if ok {
		writeJSON(w, http.StatusOK, v)
	}
}

func (s *Server) handleSigninRelayInput(w http.ResponseWriter, r *http.Request) {
	v, tenant, wk, ok := s.signinRelayOwn(w, r)
	if !ok || !s.signinRelayKindOn(w, v.Kind) {
		return
	}
	var in struct {
		Input string `json:"input"`
	}
	if decodeSmall(r, &in) != nil || !signinInputOK(in.Input) {
		writeErr(w, http.StatusBadRequest, "bad_input", "want {\"input\": 1 to 512 bytes of printable text, one line}")
		return
	}
	_, to, ok := s.signinRelayBox(w, r.Context(), tenant, v.Box)
	if !ok {
		return
	}
	sealed, err := sealSigninInput(to, v.Relay, in.Input)
	if err != nil {
		s.o.Log.Error().Str("tenant", tenant).Str("relay", v.Relay).Msg("signin_relay.seal_failed")
		writeErr(w, http.StatusServiceUnavailable, "seal_failed", "the input was not sent: it could not be sealed")
		return
	}
	ev := relayEvent{Op: wire.SigninOpInput, Relay: v.Relay, Tenant: tenant, Box: v.Box, Frame: uid.New(), Sealed: sealed}
	if !s.announceSigninRelay(w, r.Context(), wk, ev) {
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("box", v.Box).Str("relay", v.Relay).Msg("signin_relay.input_sent")
	writeJSON(w, http.StatusAccepted, map[string]string{"relay": v.Relay, "state": signinStateInputSent})
}

func (s *Server) handleSigninRelayEnd(w http.ResponseWriter, r *http.Request) {
	v, tenant, wk, ok := s.signinRelayOwn(w, r)
	if !ok {
		return
	}
	ev := relayEvent{Op: wire.SigninOpEnd, Relay: v.Relay, Tenant: tenant, Box: v.Box, Frame: uid.New()}
	if !s.announceSigninRelay(w, r.Context(), wk, ev) {
		return
	}
	s.o.Log.Info().Str("tenant", tenant).Str("box", v.Box).Str("relay", v.Relay).Msg("signin_relay.end")
	w.WriteHeader(http.StatusNoContent)
}

// signinInputOK: 1..signinRelayInputMax bytes of valid UTF-8, no control
// character (the VM presses Enter itself).
func signinInputOK(s string) bool {
	if s == "" || len(s) > signinRelayInputMax || !utf8.ValidString(s) {
		return false
	}
	return !strings.ContainsFunc(s, unicode.IsControl)
}

// sealSigninInput seals {relay, input} to the VM's desk recipient: base64
// of the age ciphertext. The plaintext lives in this call only.
func sealSigninInput(to age.Recipient, relay, input string) (string, error) {
	pt, err := json.Marshal(wire.SigninRelaySealed{Relay: relay, Input: input})
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	ew, err := age.Encrypt(&buf, to)
	if err != nil {
		return "", err
	}
	if _, err := ew.Write(pt); err != nil {
		return "", err
	}
	if err := ew.Close(); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(buf.Bytes()), nil
}

// onSigninRelayEvent is the relay listener of RunWake: fold the event in,
// and write its frame when this instance holds the VM's socket. A
// malformed event is dropped; its text is never logged.
func (s *Server) onSigninRelayEvent(payload string) {
	var ev relayEvent
	dec := json.NewDecoder(strings.NewReader(payload))
	dec.DisallowUnknownFields()
	if dec.Decode(&ev) != nil || ev.Relay == "" || ev.Tenant == "" || ev.Box == "" {
		s.o.Log.Warn().Msg("signin_relay event dropped: malformed")
		return
	}
	s.foldRelay(ev)
}

// sendSigninRelay writes x the frames of its box's live relays not yet
// written by this instance, when x's hello carried FeatureSigninRelay.
// Called on an event and after a role=box hello (the catch-up).
func (s *Server) sendSigninRelay(ctx context.Context, x *session) {
	if x.role != wire.RoleBox || !slices.Contains(x.features, wire.FeatureSigninRelay) {
		return
	}
	relays, lanes := s.relays.claim(x.tenant, x.box, s.o.Now())
	for i, lane := range lanes {
		raw, _ := json.Marshal(lane)
		if err := x.write(ctx, wire.Frame{Type: wire.TSigninRelay, MsgID: relays[i], Lane: raw}); err != nil {
			s.o.Log.Warn().Err(err).Str("tenant", x.tenant).Str("box", x.box).Str("relay", relays[i]).
				Str("op", lane.Op).Msg("signin_relay frame not written")
		}
	}
}

// onBoxAnswer routes a box's answer frame: a box sample (spec 071) or a
// sign-in relay report (spec 181 B11).
func (s *Server) onBoxAnswer(ctx context.Context, x *session, f wire.Frame) {
	if f.Type == wire.TSigninRelayOut {
		s.onSigninRelayOut(ctx, x, f)
		return
	}
	s.onBoxSamplePut(ctx, x, f)
}

// onSigninRelayOut takes the VM's report on one relay of its own (tenant,
// box), inside its deadline, and announces it to every instance, where the
// person's poll reads it. Fire and forget: a refused report is logged with
// why, never with its URL.
func (s *Server) onSigninRelayOut(ctx context.Context, x *session, f wire.Frame) {
	var out wire.SigninRelayOutLane
	dec := json.NewDecoder(bytes.NewReader(f.Lane))
	dec.DisallowUnknownFields()
	why := ""
	switch {
	case x.role != wire.RoleBox:
		why = "not a role=box socket"
	case dec.Decode(&out) != nil:
		why = "lane must be one signin_relay_out object"
	case !s.relays.live(f.MsgID, x.tenant, x.box, s.o.Now()):
		why = "unknown relay id, another box's, or past its deadline"
	default:
		why = checkSigninOut(out)
	}
	if why != "" {
		s.o.Log.Warn().Str("tenant", x.tenant).Str("box", x.box).Str("relay", f.MsgID).Str("why", why).Msg("signin_relay_out refused")
		return
	}
	wk, ok := s.o.Store.(store.SigninRelayWaker)
	if !ok {
		return
	}
	ev := relayEvent{Op: relayOpOut, Relay: f.MsgID, Tenant: x.tenant, Box: x.box, State: out.State, URL: out.URL, Reason: out.Reason}
	if s.announceRelay(ctx, wk, ev) != nil {
		return
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("relay", f.MsgID).Str("state", out.State).Msg("signin_relay.out")
}

// checkSigninOut is "" for a report the hub keeps, else why not: a known
// state, a URL only with state url and then an https URL with a host, a
// reason of one short machine word.
func checkSigninOut(o wire.SigninRelayOutLane) string {
	if !slices.Contains(wire.SigninRelayStates, o.State) {
		return "unknown state"
	}
	if (o.State == wire.SigninStateURL) != (o.URL != "") {
		return "a url comes with state url, and only then"
	}
	if o.URL != "" {
		u, err := url.Parse(o.URL)
		if err != nil || u.Scheme != "https" || u.Host == "" || len(o.URL) > signinRelayURLMax {
			return "url must be an https URL with a host"
		}
	}
	if len(o.Reason) > 64 || strings.ContainsFunc(o.Reason, func(r rune) bool { return !(r == '_' || unicode.IsLower(r) || unicode.IsDigit(r)) }) {
		return "reason must be one short lower-case word"
	}
	return ""
}
