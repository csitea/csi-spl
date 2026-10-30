package hub

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// POST /v1/fleet/enrol {tenant, box_id, pubkey, ts, sig_op, sig_new} (spec
// 158 section 4.2 item 4, row T7): a listed fleet desk box enrols a fresh
// key into a workspace marked for fleet seating. sig_op is the box's
// operator-workspace key and sig_new the new key, each over the same
// wire.FleetEnrolPayload, which names the workspace and proves possession of
// the new key. The hub pins pubkey in tenant as box_id with box_mode 'fleet'.
// It needs neither box_join_enabled nor any member holding agents.join
// (spec 158 4.5): the operator-workspace pin plus fleet_seating authorise it.
//
// Refusals after the box checks of fleet_workspaces.go: 400 bad_json (body,
// pubkey, box id or workspace id malformed, or the reserved browser box);
// 401 bad_sig (sig_new); 404 unknown_tenant; 403 workspace suspended or
// archived; 403 fleet_seating_off; 403 box_locked (the box owner lock);
// 403 fleet_pin_revoked (revoked since the box was listed); 409 stale_pin_op
// (ts not later than the pin's last op: a replay); 409 pin_conflict (the box
// id holds another live key there, or the key is live elsewhere). 201 a new
// pin, 200 the same key already live (its op ts moves); a new pin writes one
// operator_audit row on the workspace (action update, detail {fleet_enrol,
// box_mode}, actor the operator workspace and the box).

// fleetEnrolAdmit parses the body and runs the box checks and sig_new;
// false = answered.
func (s *Server) fleetEnrolAdmit(w http.ResponseWriter, r *http.Request, fd store.FleetDeskBoxes) (wire.FleetEnrolRequest, store.FleetEnrolPin, string, bool) {
	var req wire.FleetEnrolRequest
	if err := json.NewDecoder(io.LimitReader(r.Body, maxJSONBody)).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_json", "enrol body does not parse")
		return req, store.FleetEnrolPin{}, "", false
	}
	pub, err := base64.StdEncoding.DecodeString(req.PubKey)
	if err != nil || len(pub) != ed25519.PublicKeySize || !msg.ValidBoxID(req.BoxID) || req.BoxID == WUIBox ||
		!msg.ValidTenantID(req.Tenant) {
		writeErr(w, http.StatusBadRequest, "bad_json", "tenant, box_id or pubkey is malformed")
		return req, store.FleetEnrolPin{}, "", false
	}
	payload, _ := wire.FleetEnrolPayload(req.Tenant, req.BoxID, req.PubKey, req.TS)
	op, listedAt, ok := s.fleetBoxAdmit(w, r, fd, fleetProof{box: req.BoxID, ts: req.TS, sig: req.SigOp, payload: payload})
	if !ok {
		return req, store.FleetEnrolPin{}, "", false
	}
	if verify(ed25519.PublicKey(pub), payload, req.SigNew) != nil {
		writeErr(w, http.StatusUnauthorized, "bad_sig", "the new key's signature (sig_new) does not verify")
		return req, store.FleetEnrolPin{}, "", false
	}
	ts, _ := time.Parse(time.RFC3339, req.TS) // skewOK parsed it
	return req, store.FleetEnrolPin{Tenant: req.Tenant, Box: req.BoxID, PubKey: ed25519.PublicKey(pub),
		ListedAt: listedAt, OpTS: ts, Now: s.o.Now()}, op, true
}

// fleetSeatingOn loads the workspace and refuses one that is suspended,
// archived, the system workspace or not marked for fleet seating; false =
// answered.
func (s *Server) fleetSeatingOn(w http.ResponseWriter, r *http.Request, tenant string) bool {
	if _, ok := s.loadTenant(w, r, tenant); !ok {
		return false
	}
	fs, ok := s.o.Store.(store.FleetSeating)
	on := false
	if ok && tenant != store.SystemTenant {
		var err error
		if on, err = fs.FleetSeating(r.Context(), tenant); err != nil {
			writeErr(w, http.StatusServiceUnavailable, "unavailable", "the workspace's fleet seating was not read")
			return false
		}
	}
	if !on {
		writeErr(w, http.StatusForbidden, codeFleetSeatingOff, "this workspace is not marked for fleet seating")
		return false
	}
	return true
}

// POST /v1/fleet/enrol
func (s *Server) handleFleetEnrol(w http.ResponseWriter, r *http.Request) {
	fe, fd, ok := s.fleetStores(w)
	if !ok {
		return
	}
	req, pin, op, ok := s.fleetEnrolAdmit(w, r, fd)
	if !ok || !s.fleetSeatingOn(w, r, pin.Tenant) {
		return
	}
	if rf := s.adminLockRefusal(r.Context(), pin.Tenant, pin.Box, "", boxLockPathJoin); rf != nil {
		writeLockRefusal(w, rf)
		return
	}
	created, err := fe.EnrolFleetPin(r.Context(), pin)
	if fleetEnrolRefused(w, err) {
		return
	}
	code := http.StatusOK
	if created {
		code = http.StatusCreated
		if ws, ok := s.o.Store.(store.OperatorWorkspaces); ok {
			s.opAudit(r, opActor{tenant: op, hum: pin.Box, ws: ws}, pin.Tenant, store.AuditUpdate,
				map[string]any{"fleet_enrol": pin.Box, "box_mode": store.BoxModeFleet, "key": sign.Fingerprint(pin.PubKey)})
		}
	}
	s.o.Log.Info().Str("tenant", pin.Tenant).Str("box_id", pin.Box).Bool("created", created).Msg("fleet enrol")
	writeJSON(w, code, map[string]string{"tenant": pin.Tenant, "box_id": pin.Box, "pubkey": req.PubKey,
		"box_mode": store.BoxModeFleet})
}

// fleetEnrolRefused writes the store refusals; false = err is nil.
func fleetEnrolRefused(w http.ResponseWriter, err error) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, store.ErrFleetPinRevoked):
		writeErr(w, http.StatusForbidden, codeFleetPinRevoked,
			"this box's pin in the workspace was revoked after the box was listed; the operator lists the box again first")
	case errors.Is(err, store.ErrStale):
		writeErr(w, http.StatusConflict, "stale_pin_op", "ts is not later than the last op on this pin (replay?)")
	case errors.Is(err, store.ErrConflict):
		// One message for both cases, as the join (spec 108 3.1).
		writeErr(w, http.StatusConflict, "pin_conflict",
			"box_id is already seated with another key, or this key is seated elsewhere")
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "unknown_tenant", "no such tenant")
	default:
		writeErrCause(w, http.StatusInternalServerError, "internal", "pin not stored", err)
	}
	return true
}
