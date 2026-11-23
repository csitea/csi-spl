package store

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"testing"
	"time"
)

// Spec 181 row B7 (SPL-6329): the operator join-token mint. Memory always,
// Postgres with a DSN (hub-pg.tst.sh, PRE_PUSH_TIER=full). Synthetic ids only.

func opJoinToken(tenant, box string, now time.Time) JoinToken {
	b := make([]byte, 32)
	rand.Read(b) //nolint:errcheck
	return JoinToken{Hash: hex.EncodeToString(b), TenantID: tenant, CreatedBy: "HUM-1", Label: "private vm",
		BoxID: box, CreatedAt: now, ExpiresAt: now.Add(time.Hour)}
}

// The mint writes the token (bound to its box, for no member) and ONE audit
// row in the target workspace, by the operator. CONTROL: no box id, no
// workspace and a box id another workspace holds (open token, then live pin)
// are each refused and leave no token and no audit row behind.
func TestMintOperatorJoinToken(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Second)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			m, js, ow := s.(OperatorJoinMint), s.(JoinTokens), s.(OperatorWorkspaces)
			a, b := newTenant(t, s), newTenant(t, s)
			vm := "vm-" + uid("")[:8]
			jt := opJoinToken(a, vm, now)
			if err := m.MintOperatorJoinToken(ctx, jt, "ops"); err != nil {
				t.Fatalf("mint: %v", err)
			}
			toks, err := js.ListJoinTokens(ctx, a, now)
			if err != nil || len(toks) != 1 || toks[0].BoxID != vm || toks[0].ForHuman != "" || toks[0].CreatedBy != "HUM-1" {
				t.Fatalf("tokens of %s: %+v %v", a, toks, err)
			}
			trail, err := ow.OperatorAuditOf(ctx, a, 10)
			if err != nil || len(trail) != 1 || trail[0].Action != AuditMintJoinToken || trail[0].ActorTenant != "ops" ||
				trail[0].Detail["join_token"] != jt.ID() || trail[0].Detail["box_id"] != vm {
				t.Fatalf("audit of %s: %+v %v", a, trail, err)
			}
			refused := map[string]struct {
				t    JoinToken
				want error
			}{
				"no box":         {opJoinToken(b, "", now), ErrJoinTokenUnbound},
				"no workspace":   {opJoinToken("t-none-"+uid("")[:8], "vm-x", now), ErrNotFound},
				"open elsewhere": {opJoinToken(b, vm, now), ErrVMBoundElsewhere},
			}
			for why, c := range refused {
				if err := m.MintOperatorJoinToken(ctx, c.t, "ops"); !errors.Is(err, c.want) {
					t.Errorf("%s: %v, want %v", why, err, c.want)
				}
			}
			// The open token is redeemed: vm is now live-pinned in a.
			if _, err := js.RedeemJoinToken(ctx, a, jt.Hash, vm, pubkey(), BoxModeDedicated, now); err != nil {
				t.Fatalf("redeem: %v", err)
			}
			if err := m.MintOperatorJoinToken(ctx, opJoinToken(b, vm, now), "ops"); !errors.Is(err, ErrVMBoundElsewhere) {
				t.Errorf("pinned elsewhere: %v, want ErrVMBoundElsewhere", err)
			}
			if toks, _ := js.ListJoinTokens(ctx, b, now); len(toks) != 0 {
				t.Errorf("a refused mint stored %d token(s) in %s", len(toks), b)
			}
			if trail, _ := ow.OperatorAuditOf(ctx, b, 10); len(trail) != 0 {
				t.Errorf("a refused mint audited %d row(s) in %s", len(trail), b)
			}
			// CONTROL: a's own second token for vm (a re-join) is not "elsewhere".
			if err := m.MintOperatorJoinToken(ctx, opJoinToken(a, vm, now), "ops"); err != nil {
				t.Errorf("CONTROL: re-mint for the same workspace: %v", err)
			}
		})
	}
}
