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

// operatorReaders and expensesReaders are the roles of the operator workspace
// each rule admits. The Expenses section's reads (the paid items, the cost
// entries) also admit its biz_owner and internal_accountant (SPL-5420; owner
// HUM-10, t1 ea5d52a7: "Add access to the expenses section to the business
// owners and the internal accountant roles"); Costs' estate scope and the
// lanes stay the admin's and the product owner's. Read only either way.
var (
	operatorReaders = []string{rbac.Admin, rbac.ProductOwner}
	expensesReaders = []string{rbac.Admin, rbac.ProductOwner, rbac.BizOwner, rbac.InternalAccountant}
)

// readRole is a rule without the clone lookup: a holds one of roles and
// tenant is the operator workspace op. Only the operator's own members pass:
// the rows are the estate's, never another workspace's to read.
func readRole(roles []string, op, tenant string, a rbac.Access) bool {
	return op != "" && tenant == op && a.HasAny(roles...)
}

// operatorReadRole is readRole for operatorReaders.
func operatorReadRole(op, tenant string, a rbac.Access) bool {
	return readRole(operatorReaders, op, tenant, a)
}

// readsOperatorEstate is the whole rule for a member of tenant.
func (s *Server) readsOperatorEstate(ctx context.Context, op, tenant string, a rbac.Access) bool {
	return operatorReadRole(op, tenant, a) && !s.readerIsActAsClone(ctx, tenant, a.HumanID)
}

// costEstateReaders are the roles readsCostEstate adds: the accountants of
// the operator workspace, who enter the hr lines (spec 123 section 16
// follow-up 1, SPL-5433 step b). Not every costs.write holder: the operator
// workspace's biz_owner keeps its own row only (spec 140 3.10, owner msg
// 96d69790, TestCostReadEstateScope).
var costEstateReaders = []string{rbac.InternalAccountant, rbac.ExternalAccountant}

// readsCostEstate is Costs' estate scope (GET /v1/tenant/costs): the rule
// above, plus an accountant of the operator workspace, so they read the hr
// entries on Total and Persons. Never an act-as clone; the lanes and the
// other operator reads keep readsOperatorEstate.
func (s *Server) readsCostEstate(ctx context.Context, op, tenant string, a rbac.Access) bool {
	if !operatorReadRole(op, tenant, a) && !readRole(costEstateReaders, op, tenant, a) {
		return false
	}
	return !s.readerIsActAsClone(ctx, tenant, a.HumanID)
}

// readerOf is the rule for roles as a /v1/view/me flag. An act-as session is
// known there without a lookup (TestRoundTripsPerRequest); a failed read of
// the operator workspace reads false.
func (s *Server) readerOf(ctx context.Context, roles []string, tenant string, a rbac.Access, actAs bool) bool {
	if actAs || !a.HasAny(roles...) {
		return false
	}
	op, err := s.operatorTenant(ctx)
	return err == nil && readRole(roles, op, tenant, a)
}

// operatorReaderOf is operator_reader on /v1/view/me.
func (s *Server) operatorReaderOf(ctx context.Context, tenant string, a rbac.Access, actAs bool) bool {
	return s.readerOf(ctx, operatorReaders, tenant, a, actAs)
}

// expensesReaderOf is expenses_reader on /v1/view/me.
func (s *Server) expensesReaderOf(ctx context.Context, tenant string, a rbac.Access, actAs bool) bool {
	return s.readerOf(ctx, expensesReaders, tenant, a, actAs)
}

// operatorReadCaller is fleetLoadCaller for a GET: the operator service
// account as there, or a member readsOperatorEstate passes. The actor is the
// member (nil for the service account); it carries no workspace store.
func (s *Server) operatorReadCaller(w http.ResponseWriter, r *http.Request) (string, *opActor, string, bool) {
	return s.estateReadCaller(w, r, operatorReaders, "only an admin or a product owner of the operator workspace reads this")
}

// expensesReadCaller is operatorReadCaller for the Expenses section's reads,
// with expensesReaders.
func (s *Server) expensesReadCaller(w http.ResponseWriter, r *http.Request) (string, *opActor, string, bool) {
	return s.estateReadCaller(w, r, expensesReaders,
		"only an admin, a product owner, a biz_owner or an internal_accountant of the operator workspace reads this")
}

// estateReadCaller is the GET gate for roles, never a live act-as clone; why
// is the 403's message.
func (s *Server) estateReadCaller(w http.ResponseWriter, r *http.Request, roles []string, why string) (string, *opActor, string, bool) {
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
	if hum == "" || err != nil || !readRole(roles, op, t.ID, a) || s.readerIsActAsClone(r.Context(), t.ID, hum) {
		writeForbidden(w, permOperatorAdmin, why)
		return "", nil, "", false
	}
	return t.ID, &opActor{tenant: t.ID, hum: hum}, hum, true
}
