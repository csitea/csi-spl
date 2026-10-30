package store

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"
	"time"
)

// Spec 158 row T7 (rdb 0243), Memory and Postgres: an enrolment pins the key
// with box_mode fleet; the same op ts again is ErrStale (a replay); the same
// key at a later ts is created false; another key for the seated box is
// ErrConflict; a key live on another box is ErrKeyLive; a pin revoked after
// the listing is ErrFleetPinRevoked, and enrols again once the listing is
// newer than the revoke. ListFleetWorkspaces answers fleet_seating true,
// live workspaces only, with the box's pin. CONTROL: the workspace with
// fleet_seating false is not listed.
func TestFleetEnrolStore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fe, ok := st.(FleetEnrol)
			if !ok {
				t.Fatalf("%s keeps no fleet seating", name)
			}
			ws, off, box := newTenant(t, st), newTenant(t, st), uid("fe-")
			if err := st.(FleetSeating).SetFleetSeating(ctx, ws, true); err != nil {
				t.Fatal(err)
			}
			// every create sets fleet_seating true (SPL-4295): opt off out
			if err := st.(FleetSeating).SetFleetSeating(ctx, off, false); err != nil {
				t.Fatal(err)
			}
			listed := time.Now().UTC().Add(-time.Minute)
			base := time.Now().UTC().Truncate(time.Second)
			pub, _, _ := ed25519.GenerateKey(nil)
			pin := FleetEnrolPin{Tenant: ws, Box: box, PubKey: pub, ListedAt: listed, OpTS: base, Now: time.Now()}
			if created, err := fe.EnrolFleetPin(ctx, pin); err != nil || !created {
				t.Fatalf("enrol: created=%v %v", created, err)
			}
			if got, err := st.GetPin(ctx, ws, box); err != nil || !got.Equal(pub) {
				t.Fatalf("pin %v %v", got, err)
			}
			if mode, err := st.(BoxJoinSwitch).PinBoxMode(ctx, ws, box); err != nil || mode != BoxModeFleet {
				t.Fatalf("box_mode %q %v", mode, err)
			}
			if _, err := fe.EnrolFleetPin(ctx, pin); !errors.Is(err, ErrStale) {
				t.Fatalf("replay: %v, want ErrStale", err)
			}
			pin.OpTS = base.Add(time.Second)
			if created, err := fe.EnrolFleetPin(ctx, pin); err != nil || created {
				t.Fatalf("same key later: created=%v %v, want false nil", created, err)
			}
			other, _, _ := ed25519.GenerateKey(nil)
			conflict := pin
			conflict.PubKey, conflict.OpTS = other, base.Add(2*time.Second)
			if _, err := fe.EnrolFleetPin(ctx, conflict); !errors.Is(err, ErrConflict) || errors.Is(err, ErrKeyLive) {
				t.Fatalf("another key: %v, want ErrConflict", err)
			}
			elsewhere := FleetEnrolPin{Tenant: off, Box: box, PubKey: pub, ListedAt: listed, OpTS: base, Now: time.Now()}
			if _, err := fe.EnrolFleetPin(ctx, elsewhere); !errors.Is(err, ErrKeyLive) {
				t.Fatalf("key live elsewhere: %v, want ErrKeyLive", err)
			}
			got, err := fe.ListFleetWorkspaces(ctx, box)
			if err != nil {
				t.Fatal(err)
			}
			seen := map[string]bool{}
			for _, w := range got {
				seen[w.Tenant] = w.Pinned
			}
			if p, ok := seen[ws]; !ok || !p {
				t.Errorf("list %v: want %s pinned", got, ws)
			}
			if _, ok := seen[off]; ok {
				t.Errorf("CONTROL: %s with fleet_seating false is listed", off)
			}
			if err := st.RevokePin(ctx, ws, box, base.Add(3*time.Second), time.Now()); err != nil {
				t.Fatal(err)
			}
			again := pin
			again.OpTS = base.Add(4 * time.Second)
			if _, err := fe.EnrolFleetPin(ctx, again); !errors.Is(err, ErrFleetPinRevoked) {
				t.Fatalf("revoked after the listing: %v, want ErrFleetPinRevoked", err)
			}
			again.ListedAt = time.Now().UTC().Add(time.Minute)
			if created, err := fe.EnrolFleetPin(ctx, again); err != nil || !created {
				t.Fatalf("listed again: created=%v %v", created, err)
			}
			if err := st.(OperatorWorkspaces).SetWorkspaceState(ctx, ws, true, false, time.Now()); err != nil {
				t.Fatal(err)
			}
			if got, _ := fe.ListFleetWorkspaces(ctx, box); len(got) > 0 {
				for _, w := range got {
					if w.Tenant == ws {
						t.Errorf("a suspended workspace is listed: %v", got)
					}
				}
			}
		})
	}
}
