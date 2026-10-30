package action

import (
	"context"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 162 3.3, row B4 (C19): Lease checks --reason before any dial and puts
// it in the cas frame as lease_reason.

// leaseHub answers a lease frame with an empty answer object.
func leaseHub(t *testing.T) *opHub {
	t.Helper()
	return newOpHub(t, func(f wire.Frame) wire.Frame {
		if f.Type != wire.TLease {
			return wire.Frame{Type: wire.TError, Error: "unexpected_frame"}
		}
		return wire.Frame{Type: wire.TLease, MsgID: f.MsgID, Lease: []byte(`{"won":true}`)}
	})
}

// TestLeaseReasonRefused: an unknown reason, or a reason on a read, never dials.
func TestLeaseReasonRefused(t *testing.T) {
	h := leaseHub(t)
	cfg := opCfg(t, h.url)
	for name, c := range map[string]struct {
		in   LeaseArgs
		want string
	}{
		"bogus":       {LeaseArgs{Fleet: "csi", Role: "orch", Holder: "c-007@box-a", Reason: "bogus"}, "--reason must be one of claim, rotation, seat_move, failover, handback, vendor, limit"},
		"upper case":  {LeaseArgs{Fleet: "csi", Role: "orch", Holder: "c-007@box-a", Reason: "Failover"}, "--reason must be one of"},
		"read reason": {LeaseArgs{Fleet: "csi", Role: "orch", Reason: "claim"}, "it needs --holder"},
	} {
		t.Run(name, func(t *testing.T) {
			if out, err := Lease(context.Background(), cfg, c.in); err == nil || !strings.Contains(err.Error(), c.want) || out != nil {
				t.Fatalf("got %s, %v; want %q", out, err, c.want)
			}
		})
	}
	if n := len(h.of("")); n != 0 {
		t.Errorf("the hub received %d frames for refused requests", n)
	}
}

// TestLeaseReasonSent: each reason reaches the hub as lease_reason; none
// sends none (the frame an old CLI sends).
func TestLeaseReasonSent(t *testing.T) {
	h := leaseHub(t)
	cfg := opCfg(t, h.url)
	reasons := append([]string{""}, wire.LeaseReasons...)
	for i, r := range reasons {
		if _, err := Lease(context.Background(), cfg, LeaseArgs{Fleet: "csi", Role: "orch", Holder: "c-007@box-a", IfGen: 3, Reason: r}); err != nil {
			t.Fatalf("reason %q: %v", r, err)
		}
		fs := h.of(wire.TLease)
		if len(fs) != i+1 || fs[i].LeaseOp != "cas" || fs[i].LeaseReason != r || fs[i].IfGen != 3 {
			t.Fatalf("reason %q: frames %+v", r, fs)
		}
	}
}
