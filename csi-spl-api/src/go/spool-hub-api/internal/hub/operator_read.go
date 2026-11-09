package hub

import (
	"context"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// The one home of who READS the operator's costs, expenses and lanes (SPL-5181;
// owner HUM-10, t1 8426e63e msgs b17ead41 and 573da484, t1 36406a93 msg
// 97bab339): the operator workspace's admin or product owner, never an act-as
// clone (SPL-4187). Read only: every write stays on fleetLoadCaller.

// opCallerGate is fleetLoadCaller's shape, which operatorReadCaller shares.
type opCallerGate func(http.ResponseWriter, *http.Request) (string, *opActor, string, bool)

// operatorReadRole is the rule without the clone lookup: a is an admin or a
// product owner and tenant is the operator workspace op.
func operatorReadRole(op, tenant string, a rbac.Access) bool {
	return op != "" && tenant == op && a.HasAny(rbac.Admin, rbac.ProductOwner)
}

// readsOperatorEstate is the whole rule for a member of tenant.
func (s *Server) readsOperatorEstate(ctx context.Context, op, tenant string, a rbac.Access) bool {
	return operatorReadRole(op, tenant, a) && !s.readerIsActAsClone(ctx, tenant, a.HumanID)
}

// operatorReaderOf is the rule as /v1/view/me's flag. An act-as session is
// known there without a lookup (TestRoundTripsPerRequest); a failed read of
// the operator workspace reads false.
func (s *Server) operatorReaderOf(ctx context.Context, tenant string, a rbac.Access, actAs bool) bool {
	if actAs || !a.HasAny(rbac.Admin, rbac.ProductOwner) {
		return false
	}
	op, err := s.operatorTenant(ctx)
	return err == nil && operatorReadRole(op, tenant, a)
}

// operatorReadCaller is fleetLoadCaller for a GET: the operator service
// account as there, or a member readsOperatorEstate passes. The actor is the
// member (nil for the service account); it carries no workspace store.
func (s *Server) operatorReadCaller(w http.ResponseWriter, r *http.Request) (string, *opActor, string, bool) {
	if strings.HasPrefix(strings.TrimSpace(r.Header.Get("Authorization")), "Bearer ") {
		return s.fleetLoadCaller(w, r)
	}
	s.allowOrigin(w, r)
	w.Header().Set("Cache-Control", "no-store")
	op, err := s.operatorTenant(r.Context())
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "the operator workspace was not read")
		return "", nil, "", false
	}
	if op == "" {
		writeErr(w, http.StatusNotFound, "not_found", "this hub names no operator workspace")
		return "", nil, "", false
	}
	t, hum, ok := s.humanTenant(w, r)
	if !ok {
		return "", nil, "", false
	}
	a, err := s.access(r.Context(), hum, t.ID)
	if hum == "" || err != nil || !s.readsOperatorEstate(r.Context(), op, t.ID, a) {
		writeForbidden(w, permOperatorAdmin, "only an admin or a product owner of the operator workspace reads this")
		return "", nil, "", false
	}
	return t.ID, &opActor{tenant: t.ID, hum: hum}, hum, true
}
