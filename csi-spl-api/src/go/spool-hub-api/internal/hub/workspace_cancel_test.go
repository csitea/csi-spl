package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 181 row B9 (SPL-6344): a private workspace's cancel. Synthetic ids
// and the fake key sk-test-0000 only.

// cancelEnv is vkEnv with the operator routes on: the token "good" is the
// env's service account, "stranger" a verified identity that is not.
func cancelEnv(t *testing.T) *env {
	t.Helper()
	e, _ := vkEnv(t, func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			switch token {
			case "good":
				return operatorSA, nil
			case "stranger":
				return "someone@example.com", nil
			}
			return "", errors.New("token rejected")
		}
	})
	return e
}

// leasingBox is a private workspace whose dedicated box leases claude:
// plan private_vm, the box approved and enrolled, a key set.
func leasingBox(t *testing.T, e *env) (tid string, h hubclient.VendorKeyHub) {
	t.Helper()
	ctx := context.Background()
	tid, _ = e.tenant()
	if err := e.st.(store.PricePlans).PutPricePlan(ctx, tid, store.PrivateVMPlan()); err != nil {
		t.Fatal(err)
	}
	biz := seat(t, e, tid, rbac.BizOwner)
	b := keyBox(t, e, tid, "box-vm", store.BoxModeDedicated)
	if err := e.st.(store.VendorKeyLeases).ApproveVendorKeyBox(ctx, tid, "box-vm", biz, time.Now()); err != nil {
		t.Fatal(err)
	}
	if code, body := putKey(t, e, tid, "claude", biz, nil); code != http.StatusNoContent {
		t.Fatalf("PUT key = %d %v", code, body)
	}
	enrolDesk(t, e, tid, "box-vm")
	return tid, hubclient.VendorKeyHub{C: b.c}
}

func cancelPath(tid string) string { return "/v1/operator/workspaces/" + tid + "/cancel" }

// TestWorkspaceCancelLease403 is row B9's red control: a cancelled
// workspace's seat asks a lease -> 403 workspace_cancelled. The seat holds
// the upload token of a session it opened before the cancel, as a running
// desk does. CONTROL: the same token's lease before the cancel is 200, so
// the 403 is the cancel's, not a dead path.
func TestWorkspaceCancelLease403(t *testing.T) {
	e := cancelEnv(t)
	ctx := context.Background()
	tid, h := leasingBox(t, e)
	sess, err := h.C.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	tok, err := sess.UploadToken(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if code, body := leaseWith(t, e, tid, tok); code != http.StatusOK {
		t.Fatalf("CONTROL: the lease before the cancel = %d %s, want 200", code, body)
	}
	code, out := opCall(t, e, tid, http.MethodPost, cancelPath(tid), "good", map[string]any{"workspace_id": tid})
	if code != http.StatusCreated || out["replayed"] != false || out["revoked_join_tokens"] != float64(0) {
		t.Fatalf("cancel = %d %v, want 201", code, out)
	}
	if boxes, _ := out["revoked_boxes"].([]any); len(boxes) != 1 || boxes[0] != "box-vm" {
		t.Fatalf("revoked_boxes = %v, want [box-vm]", out["revoked_boxes"])
	}
	if code, body := leaseWith(t, e, tid, tok); code != http.StatusForbidden || body != "workspace_cancelled" {
		t.Fatalf("RED: the cancelled workspace's seat asked a lease = %d %s, want 403 workspace_cancelled", code, body)
	}
	if _, err := h.Lease(ctx, "claude"); err == nil {
		t.Fatal("a fresh session of the revoked box leased a key")
	}
	if _, err := e.st.GetPin(ctx, tid, "box-vm"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("the pin after the cancel: %v, want revoked", err)
	}
	code, out = opCall(t, e, tid, http.MethodPost, cancelPath(tid), "good", map[string]any{"workspace_id": tid})
	if code != http.StatusOK || out["replayed"] != true {
		t.Fatalf("replay = %d %v, want 200 replayed", code, out)
	}
}

// leaseWith posts the claude lease with a box's upload token and answers
// the HTTP status and the error code ("" on a 200).
func leaseWith(t *testing.T, e *env, tid, tok string) (int, string) {
	t.Helper()
	code, out := opCall(t, e, tid, http.MethodPost, "/v1/vendor-keys/claude/lease", tok, nil)
	s, _ := out["error"].(string)
	return code, s
}

// TestWorkspaceCancelRefusals: only the env's operator cancels; the body
// names the URL's workspace; a shared workspace or none is refused, and
// each refusal leaves the lease answered.
func TestWorkspaceCancelRefusals(t *testing.T) {
	e := cancelEnv(t)
	ctx := context.Background()
	tid, h := leasingBox(t, e)
	shared, _ := e.tenant()
	for _, c := range []struct {
		name, tid, token string
		body             map[string]any
		want             int
	}{
		{"no token", tid, "", map[string]any{"workspace_id": tid}, http.StatusUnauthorized},
		{"forged", tid, "forged", map[string]any{"workspace_id": tid}, http.StatusUnauthorized},
		{"not an operator", tid, "stranger", map[string]any{"workspace_id": tid}, http.StatusForbidden},
		{"body names another", tid, "good", map[string]any{"workspace_id": shared}, http.StatusBadRequest},
		{"unknown field", tid, "good", map[string]any{"workspace_id": tid, "force": true}, http.StatusBadRequest},
		{"shared workspace", shared, "good", map[string]any{"workspace_id": shared}, http.StatusConflict},
		{"no workspace", "t-none", "good", map[string]any{"workspace_id": "t-none"}, http.StatusNotFound},
	} {
		if code, out := opCall(t, e, tid, http.MethodPost, cancelPath(c.tid), c.token, c.body); code != c.want {
			t.Errorf("%s: %d %v, want %d", c.name, code, out, c.want)
		}
	}
	if _, err := h.Lease(ctx, "claude"); err != nil {
		t.Fatalf("CONTROL: a refused cancel stopped the lease: %v", err)
	}
}
