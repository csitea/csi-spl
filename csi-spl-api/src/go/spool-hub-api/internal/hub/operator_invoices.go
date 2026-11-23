package hub

import (
	"errors"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The owner's overdue list (spec 181 row B13, gap G14; Q-17 B, Q-18 C): a
// private workspace's monthly invoice is paid by bank transfer, due 14 days
// net from its issue date (Q-19 A). One that is unpaid past its due date is
// listed here, and the owner decides each case by hand: nothing is decided
// automatically, the workspace keeps working. When the transfer arrives,
// the owner marks the invoice paid.
//
//	GET  /v1/operator/invoices/overdue
//	  200 {"as_of", "invoices": [{workspace, workspace_name, month, currency, humans,
//	       seat_cents, vm_cost_micros, vm_price_micros, total_micros, issued_on,
//	       due_on, days_overdue, reminded_at}]}   oldest due date first
//	POST /v1/operator/invoices/{id}/{month}/paid    month = YYYY-MM
//	  200 {"workspace", "month", "paid_at"}
//	  400 bad_tenant | bad_month    404 not_found    409 already_paid
//
// Who may: the operator workspace's admin only (operatorActor); any other
// caller, a workspace's own members included, gets 403, and an act-as clone
// reads the list but marks nothing paid. Each call writes one operator_audit
// row: the list a `list` row in the operator workspace, a mark paid an
// `update` row in the invoice's workspace, {invoice_paid: <month>, ...}.

// invoiceMonthLayout is the {month} of the mark paid route.
const invoiceMonthLayout = "2006-01"

type overdueInvoiceJSON struct {
	Workspace     string  `json:"workspace"`
	WorkspaceName string  `json:"workspace_name"`
	Month         string  `json:"month"`
	Currency      string  `json:"currency"`
	Humans        int64   `json:"humans"`
	SeatCents     int64   `json:"seat_cents"`
	VMCostMicros  int64   `json:"vm_cost_micros"`
	VMPriceMicros string  `json:"vm_price_micros"`
	TotalMicros   string  `json:"total_micros"`
	IssuedOn      string  `json:"issued_on"`
	DueOn         string  `json:"due_on"`
	DaysOverdue   int     `json:"days_overdue"`
	RemindedAt    *string `json:"reminded_at"`
}

func (s *Server) routeOperatorInvoices(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/invoices/overdue", s.handleOverdueInvoices)
	mux.HandleFunc("POST /v1/operator/invoices/{id}/{month}/paid", s.handleInvoicePaid)
	mux.HandleFunc("OPTIONS /v1/operator/invoices/overdue", s.operatorWorkspacesPreflight)
	mux.HandleFunc("OPTIONS /v1/operator/invoices/{id}/{month}/paid", s.operatorWorkspacesPreflight)
}

// GET /v1/operator/invoices/overdue
func (s *Server) handleOverdueInvoices(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	od, ok := s.o.Store.(store.OverdueInvoices)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no invoices")
		return
	}
	now := s.o.Now().UTC()
	list, err := od.OverdueInvoices(r.Context(), now)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("operator overdue invoices")
		writeErr(w, http.StatusInternalServerError, "internal", "overdue invoices not read")
		return
	}
	names := s.workspaceNames(r, a)
	out := make([]overdueInvoiceJSON, 0, len(list))
	for _, inv := range list {
		out = append(out, overdueJSON(inv, names[inv.Tenant], now))
	}
	s.opAudit(r, a, a.tenant, store.AuditList, map[string]any{"overdue_invoices": len(out)})
	writeJSON(w, http.StatusOK, map[string]any{"as_of": rfc(now), "invoices": out})
}

// workspaceNames maps each workspace id to its display name; empty when the
// list is not read (the ids still show).
func (s *Server) workspaceNames(r *http.Request, a opActor) map[string]string {
	names := map[string]string{}
	list, err := a.ws.ListWorkspaces(r.Context())
	if err != nil {
		s.o.Log.Warn().Err(err).Msg("operator overdue invoices: workspace names")
		return names
	}
	for _, ws := range list {
		names[ws.ID] = ws.DisplayName
	}
	return names
}

func overdueJSON(inv store.Invoice, name string, now time.Time) overdueInvoiceJSON {
	out := overdueInvoiceJSON{Workspace: inv.Tenant, WorkspaceName: name, Month: inv.Month.Format(invoiceMonthLayout),
		Currency: inv.Currency, Humans: inv.Humans, SeatCents: inv.SeatCents, VMCostMicros: inv.VMCostMicros,
		VMPriceMicros: inv.VMPriceMicros, TotalMicros: inv.TotalMicros, IssuedOn: inv.IssuedOn.Format(time.DateOnly),
		DueOn: inv.DueOn.Format(time.DateOnly), DaysOverdue: int(now.Sub(inv.DueOn).Hours() / 24)}
	if inv.RemindedAt != nil {
		at := rfc(*inv.RemindedAt)
		out.RemindedAt = &at
	}
	return out
}

// POST /v1/operator/invoices/{id}/{month}/paid
func (s *Server) handleInvoicePaid(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	id := r.PathValue("id")
	if !msg.ValidTenantID(id) {
		writeErr(w, http.StatusBadRequest, "bad_tenant", "id must be a valid workspace slug")
		return
	}
	month, err := time.Parse(invoiceMonthLayout, r.PathValue("month"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_month", "month must be YYYY-MM")
		return
	}
	invs, ok := s.o.Store.(store.Invoices)
	if !ok {
		writeErr(w, http.StatusNotImplemented, "unsupported", "this hub's store keeps no invoices")
		return
	}
	inv, err := invs.Invoice(r.Context(), id, month)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no invoice of this workspace for this month")
		return
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", "invoice not read")
		return
	case inv.PaidAt != nil:
		writeErr(w, http.StatusConflict, "already_paid", "this invoice is already marked paid")
		return
	}
	at := s.o.Now().UTC()
	if err := invs.MarkInvoicePaid(r.Context(), id, month, at); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", id).Msg("operator invoice paid")
		writeErr(w, http.StatusInternalServerError, "internal", "invoice not marked paid")
		return
	}
	s.opAudit(r, a, id, store.AuditUpdate, map[string]any{"invoice_paid": month.Format(invoiceMonthLayout),
		"total_micros": inv.TotalMicros, "currency": inv.Currency, "due_on": inv.DueOn.Format(time.DateOnly)})
	writeJSON(w, http.StatusOK, map[string]any{"workspace": id, "month": month.Format(invoiceMonthLayout), "paid_at": rfc(at)})
}
