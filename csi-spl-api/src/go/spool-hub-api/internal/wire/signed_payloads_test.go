package wire_test

import (
	"slices"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Golden tests for the bytes a box key signs (refactor round 20 row 07):
// each builder against the literal its doc comment states, the jq -cS shape
// (sorted keys, its op). One changed byte breaks every box's enrol or join.

// spGolden fails when a payload builder's bytes differ from want.
func spGolden(t *testing.T, name string, got []byte, err error, want string) {
	t.Helper()
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	if string(got) != want {
		t.Errorf("%s:\n got  %s\n want %s", name, got, want)
	}
}

func TestSignedPayloadsFleetGolden(t *testing.T) {
	got, err := wire.FleetWorkspacesPayload("box-1", "2026-11-01T00:00:00Z")
	spGolden(t, "FleetWorkspacesPayload", got, err,
		`{"box_id":"box-1","op":"fleet_workspaces","ts":"2026-11-01T00:00:00Z"}`)

	got, err = wire.FleetEnrolPayload("t1", "box-1", "PUB", "2026-11-01T00:00:00Z")
	spGolden(t, "FleetEnrolPayload", got, err,
		`{"box_id":"box-1","op":"fleet_enrol","pubkey":"PUB","tenant":"t1","ts":"2026-11-01T00:00:00Z"}`)
}

func TestSignedPayloadsJoinKeyGolden(t *testing.T) {
	cases := []struct {
		name, mode, x25519, want string
	}{
		{"x25519 no mode", "", "X",
			`{"box_id":"box-1","box_x25519":"X","op":"join","pubkey":"PUB","token_hash":"TH","ts":"1"}`},
		{"x25519 and mode", "shared", "X",
			`{"box_id":"box-1","box_mode":"shared","box_x25519":"X","op":"join","pubkey":"PUB","token_hash":"TH","ts":"1"}`},
	}
	for _, c := range cases {
		got, err := wire.JoinKeyPayload("TH", "box-1", "PUB", "1", c.mode, c.x25519)
		spGolden(t, "JoinKeyPayload "+c.name, got, err, c.want)
	}
}

func TestSignedPayloadsJoinKeyNoX25519IsJoinMode(t *testing.T) {
	for _, mode := range []string{"", "dedicated", "shared"} {
		got, err := wire.JoinKeyPayload("TH", "box-1", "PUB", "1", mode, "")
		want, werr := wire.JoinModePayload("TH", "box-1", "PUB", "1", mode)
		if err != nil || werr != nil {
			t.Fatalf("mode %q: %v %v", mode, err, werr)
		}
		if string(got) != string(want) {
			t.Errorf("mode %q: JoinKeyPayload %s != JoinModePayload %s", mode, got, want)
		}
	}
}

func TestSignedPayloadsValidLeaseReason(t *testing.T) {
	if !wire.ValidLeaseReason("") {
		t.Error(`ValidLeaseReason("") = false, want true (none is valid)`)
	}
	for _, r := range wire.LeaseReasons {
		if !wire.ValidLeaseReason(r) {
			t.Errorf("ValidLeaseReason(%q) = false, want true", r)
		}
	}
	if slices.Contains(wire.LeaseReasons, "x") || wire.ValidLeaseReason("x") {
		t.Error(`ValidLeaseReason("x") = true, want false`)
	}
}

func TestSignedPayloadsInnerMsgID(t *testing.T) {
	good := []byte(`{"v":1,"msg":{"v":1,"msg_id":"m-123","from":"c-001"}}`)
	if got := wire.InnerMsgID(good); got != "m-123" {
		t.Errorf("InnerMsgID(good) = %q, want m-123", got)
	}
	for _, bad := range []string{`not json`, `{"msg":"oops"}`, ``} {
		if got := wire.InnerMsgID([]byte(bad)); got != "" {
			t.Errorf("InnerMsgID(%q) = %q, want empty", bad, got)
		}
	}
}
