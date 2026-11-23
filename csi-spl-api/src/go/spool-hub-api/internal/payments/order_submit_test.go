package payments

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 181 row B2 (Q-18 C): POST /api/v1/checkout/private-workspace takes an
// order only and creates the workspace at once. Done test: a submit -> one
// tenant, one order, box_join_enabled true, zero provider calls. RED
// CONTROLS: a submit that reaches the provider stub fails its test; the
// submit replayed -> one tenant and one order, not two. The order is a
// signed-in person's (4.1 step 1): no session -> 401 and no tenant; a body
// email that is not the session's -> no tenant for that email.

// countingRail is a card AND wallet rail that counts every call: the order
// submit must never reach it.
type countingRail struct{ calls []string }

func (c *countingRail) CreateIntent(context.Context, string, int, string) (string, string, error) {
	c.calls = append(c.calls, "CreateIntent")
	return "pi_x", "pi_secret_x", nil
}
func (c *countingRail) CreateIntentWithItems(context.Context, string, int, string, []LineItem) (string, string, error) {
	c.calls = append(c.calls, "CreateIntentWithItems")
	return "pi_x", "pi_secret_x", nil
}
func (c *countingRail) Refund(context.Context, string, int) error {
	c.calls = append(c.calls, "Refund")
	return nil
}
func (c *countingRail) CancelIntent(context.Context, string) error {
	c.calls = append(c.calls, "CancelIntent")
	return nil
}
func (c *countingRail) CreateProviderOrder(context.Context, string, int, string) (string, string, error) {
	c.calls = append(c.calls, "CreateProviderOrder")
	return "o_x", "https://approve.example.test", nil
}
func (c *countingRail) CaptureProviderOrder(context.Context, string, string) (string, string, error) {
	c.calls = append(c.calls, "CaptureProviderOrder")
	return "cap_x", "payer_x", nil
}

// fakeSessions is the hub's session check in a test: signed in as email,
// or no session at all when email is "".
type fakeSessions struct{ email string }

func (f *fakeSessions) SessionFromRequest(*http.Request) (auth.Session, bool) {
	if f.email == "" {
		return auth.Session{}, false
	}
	return auth.Session{V: 1, Provider: "google", Subject: "sub-1", Email: f.email}, true
}

// orderHandler is a handler on the fake rail whose card and wallet are rail,
// with the buyer signed in.
func orderHandler(t *testing.T, rail *countingRail) (*Handler, *store.Memory, *mail.Recorder) {
	t.Helper()
	h, st, rec, _ := orderHandlerAs(t, rail, &fakeSessions{email: "buyer@example.com"})
	return h, st, rec
}

func orderHandlerAs(t *testing.T, rail *countingRail, sess Sessions) (*Handler, *store.Memory, *mail.Recorder, Sessions) {
	t.Helper()
	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"})
	st, rec := store.NewMemory(), &mail.Recorder{}
	h, err := New(cfg, Deps{Store: st, Log: zerolog.Nop(), Mail: rec, MailDelivers: true,
		TenantHostPattern: pattern, Card: rail, PayPal: rail, Sessions: sess})
	if err != nil {
		t.Fatal(err)
	}
	return h, st, rec, sess
}

const orderBody = `{"tenant_id":"acme-private","email":"buyer@example.com","seats_users":4,
	"billing":{"name":"FirstName LastName Oy","address":"1 Example Street, 00100 City","country":"fi","vat_id":"FI00000000"}}`

func postOrder(h *Handler, body string) (int, map[string]any) {
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("POST", RouteOrder, strings.NewReader(body)))
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

func TestOrderSubmitCreatesWorkspaceWithoutProvider(t *testing.T) {
	rail := &countingRail{}
	h, st, rec := orderHandler(t, rail)
	ctx := context.Background()
	code, out := postOrder(h, orderBody)
	if code != 201 || out["status"] != store.OrderSubmitted || out["replayed"] != false || out["payment"] != "bank_transfer" {
		t.Fatalf("submit: %d %v", code, out)
	}
	if len(rail.calls) != 0 {
		t.Fatalf("the order submit reached the payment provider: %v (Q-18 C: zero provider calls)", rail.calls)
	}
	if _, ok := out["client_secret"]; ok {
		t.Fatalf("the answer carries a payment secret: %v", out)
	}
	tn, err := st.GetTenant(ctx, "acme-private")
	if err != nil || tn.SeatsUsers != 4 || tn.PlanID != store.PlanKindPrivateVM {
		t.Fatalf("tenant: %+v %v", tn, err)
	}
	if on, err := st.BoxJoinEnabled(ctx, "acme-private"); err != nil || !on {
		t.Fatalf("box_join_enabled = %v %v, want true", on, err)
	}
	o, err := st.WorkspaceOrder(ctx, "acme-private")
	if err != nil || o.ID != out["order_id"] || o.Billing.Country != "FI" || o.Billing.VATID != "FI00000000" {
		t.Fatalf("order: %+v %v (answer %v)", o, err, out)
	}
	if n := len(rec.Messages()); n != 0 {
		t.Fatalf("the submit sent %d mail(s); the paid path's claim mail plays no part", n)
	}
}

// RED CONTROL: the replay answers the first order (200, same id); the
// tenant keeps the first key; another email on the slug is a 409.
func TestOrderSubmitReplayIsOneOrder(t *testing.T) {
	rail := &countingRail{}
	h, st, _ := orderHandler(t, rail)
	code1, first := postOrder(h, orderBody)
	t1, _ := st.GetTenant(context.Background(), "acme-private")
	code2, again := postOrder(h, orderBody)
	t2, _ := st.GetTenant(context.Background(), "acme-private")
	if code1 != 201 || code2 != 200 || again["order_id"] != first["order_id"] || again["replayed"] != true {
		t.Fatalf("replay: %d %v then %d %v, want 201 then 200 with the same order", code1, first, code2, again)
	}
	if !t1.RootPubKey.Equal(t2.RootPubKey) {
		t.Fatal("the replay re-keyed the tenant: a second tenant creation ran")
	}
	h.d.Sessions = &fakeSessions{email: "someone-else@example.com"}
	other := strings.Replace(orderBody, `"email":"buyer@example.com",`, "", 1)
	if code, out := postOrder(h, other); code != 409 || out["error"] != "tenant_taken" {
		t.Fatalf("another person on the slug: %d %v, want 409 tenant_taken", code, out)
	}
	if len(rail.calls) != 0 {
		t.Fatalf("provider calls: %v", rail.calls)
	}
}

func TestOrderSubmitRefusals(t *testing.T) {
	h, st, _ := orderHandler(t, &countingRail{})
	if err := st.CreateTenant(context.Background(), store.Tenant{ID: "taken", RootPubKey: make([]byte, 32)}); err != nil {
		t.Fatal(err)
	}
	for name, c := range map[string]struct {
		from, to string
		code     int
		token    string
	}{
		"bad slug":      {`"acme-private"`, `"A B"`, 400, "bad_tenant_id"},
		"bad email":     {`"buyer@example.com"`, `"nobody"`, 400, "email_mismatch"},
		"no seats":      {`"seats_users":4`, `"seats_users":0`, 400, "bad_seats"},
		"too many":      {`"seats_users":4`, `"seats_users":1001`, 400, "bad_seats"},
		"no address":    {`"1 Example Street, 00100 City"`, `""`, 400, "bad_billing"},
		"bad country":   {`"country":"fi"`, `"country":"fin"`, 400, "bad_billing"},
		"tenant exists": {`"acme-private"`, `"taken"`, 409, "tenant_taken"},
	} {
		code, out := postOrder(h, strings.Replace(orderBody, c.from, c.to, 1))
		if code != c.code || out["error"] != c.token {
			t.Errorf("%s: %d %v, want %d %s", name, code, out, c.code, c.token)
		}
	}
	if code, _ := postOrder(h, `{`); code != 400 {
		t.Errorf("bad json: %d, want 400", code)
	}
}

// RED CONTROL (4.1 step 1): no session, or a session with no email, is 401
// and makes no tenant and no provider call.
func TestOrderSubmitNeedsSession(t *testing.T) {
	for name, sess := range map[string]Sessions{"no sign-in wired": nil, "no session": &fakeSessions{},
		"session without email": emptyEmailSessions{}} {
		rail := &countingRail{}
		h, st, _, _ := orderHandlerAs(t, rail, sess)
		if code, out := postOrder(h, orderBody); code != 401 || out["error"] != "unauthorized" {
			t.Errorf("%s: %d %v, want 401 unauthorized", name, code, out)
		}
		if _, err := st.GetTenant(context.Background(), "acme-private"); err == nil {
			t.Errorf("%s: a tenant was made without a signed-in person", name)
		}
		if len(rail.calls) != 0 {
			t.Errorf("%s: provider calls %v", name, rail.calls)
		}
	}
}

type emptyEmailSessions struct{}

func (emptyEmailSessions) SessionFromRequest(*http.Request) (auth.Session, bool) {
	return auth.Session{V: 1, Provider: "google", Subject: "sub-2"}, true
}

// RED CONTROL: the owner is the session's email. A body naming a stranger
// is 400 and makes no tenant; a body with no email orders for the session.
func TestOrderSubmitEmailIsTheSessions(t *testing.T) {
	h, st, _, _ := orderHandlerAs(t, &countingRail{}, &fakeSessions{email: "Buyer@Example.com"})
	ctx := context.Background()
	stranger := strings.Replace(orderBody, "buyer@example.com", "stranger@example.com", 1)
	if code, out := postOrder(h, stranger); code != 400 || out["error"] != "email_mismatch" {
		t.Fatalf("a stranger's email: %d %v, want 400 email_mismatch", code, out)
	}
	if _, err := st.GetTenant(ctx, "acme-private"); err == nil {
		t.Fatal("a tenant was made for a stranger's email")
	}
	noEmail := strings.Replace(orderBody, `"email":"buyer@example.com",`, "", 1)
	code, out := postOrder(h, noEmail)
	if code != 201 || out["email"] != "buyer@example.com" {
		t.Fatalf("no body email: %d %v, want 201 for the session's email", code, out)
	}
	if o, err := st.WorkspaceOrder(ctx, "acme-private"); err != nil || o.Email != "buyer@example.com" {
		t.Fatalf("order email: %+v %v, want the session's", o, err)
	}
}
