package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 123 13.8 row P03, 13.6: the handler wires the human mask from the
// reader's own permissions in the workspace read. The operator admin (the
// estate read) and a customer workspace's biz_owner (hours.read) get the
// money mask; a developer (costs.read only) and the customer workspace's
// admin get the Human part whole-masked. No role holds both costs.read and
// hours.rates today (time_accountant has no costs.read), so none is 200 with
// human_mask none here; costProjectHumanMask's unit test covers it.
// CONTROL: the operator admin's Human part, which the developer is denied,
// keeps its words (complete: P02 reads the hours, none booked), so not_shown
// is the mask, not the fold.
func TestCostProjectHumanMaskHTTP(t *testing.T) {
	e, op, other, who, whoOther, _ := costReadEnv(t)
	const path = "/v1/tenant/costs/project?month=2011-03"
	for _, c := range []struct {
		name, tenant, seat, mask string
	}{
		{"operator admin", op, who[rbac.Admin], "money"},
		{"customer biz_owner", other, whoOther[rbac.BizOwner], "money"},
		{"operator developer", op, who[rbac.Developer], "whole"},
		{"customer admin", other, whoOther[rbac.Admin], "whole"},
	} {
		code, body := call(t, e, c.tenant, http.MethodGet, path, c.seat, nil)
		_, by := projectParts(t, body)
		h := by["human"]
		if code != http.StatusOK || body["human_mask"] != c.mask || h == nil || h["usd_micros"] != nil || h["share"] != nil {
			t.Errorf("%s: %d mask %v human %v, want 200, mask %s, no money", c.name, code, body["human_mask"], h, c.mask)
			continue
		}
		if want := map[string]string{"money": "complete", "whole": "not_shown"}[c.mask]; h["completeness"] != want {
			t.Errorf("%s: human completeness %v, want %s", c.name, h["completeness"], want)
		}
	}
	_, body := call(t, e, op, http.MethodGet, path, who[rbac.Admin], nil)
	if _, by := projectParts(t, body); by["human"]["completeness"] != "complete" {
		t.Errorf("CONTROL: operator admin human %v, want complete (the fold's word)", by["human"])
	}
}
