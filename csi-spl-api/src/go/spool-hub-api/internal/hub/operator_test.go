package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/invitemail"
)

// A stand-in for the env's service-account email (never a real one).
const operatorSA = "spl-dev@example-dev.iam.gserviceaccount.com"

// opCall makes an operator request: a Bearer token, no member session.
func opCall(t *testing.T, e *env, tid, method, path, token string, body any) (int, map[string]any) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, e.url(tid)+path, rd)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

// The backend operator invite surface (CLE-77780): the hub, not the box, mails
// the invite. Happy path create/resend/revoke, then the auth CONTROLS (no
// token, bad token, a verified-but-not-allow-listed identity) and the disabled
// hub answering 404.
func TestOperatorInviteRoutes(t *testing.T) {
	const aud = "https://api.dev.example"
	var mu sync.Mutex
	var sent []string
	e := rbacEnv(t, func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = aud
		o.OperatorVerify = func(_ context.Context, token, gotAud string) (string, error) {
			if gotAud != aud {
				return "", errors.New("wrong audience")
			}
			switch token {
			case "good":
				return operatorSA, nil
			case "other-sa":
				return "intruder@example-dev.iam.gserviceaccount.com", nil
			default:
				return "", errors.New("token rejected")
			}
		}
		o.OperatorMail = func(_ context.Context, tenant, email, locale string) (invitemail.Result, error) {
			mu.Lock()
			defer mu.Unlock()
			sent = append(sent, tenant+"|"+email+"|"+locale)
			return invitemail.Result{Outcome: invitemail.Sent, Delivered: true, MessageID: "<m@h>", To: "digest"}, nil
		}
	})
	tid, _ := e.tenant()
	pending := "op-pending@example.com"

	// create + mail, recording HUM-10 as the inviter
	code, body := opCall(t, e, tid, http.MethodPost, "/v1/operator/invites", "good",
		map[string]any{"tenant": tid, "email": pending, "role": "developer", "invited_by": "HUM-10"})
	if code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, body)
	}
	m, _ := body["mail"].(map[string]any)
	if body["invited_by"] != "HUM-10" || m["outcome"] != invitemail.Sent || m["delivered"] != true {
		t.Fatalf("create body: %v", body)
	}
	mu.Lock()
	if len(sent) != 1 || sent[0] != tid+"|"+pending+"|" {
		t.Fatalf("sent: %v", sent)
	}
	mu.Unlock()

	// resend
	if code, body := opCall(t, e, tid, http.MethodPost, "/v1/operator/invites/mail", "good",
		map[string]any{"tenant": tid, "email": pending}); code != http.StatusOK {
		t.Fatalf("resend: %d %v", code, body)
	}

	// no_mail: the invite is stored, nothing is sent
	mailsBefore := len(sent)
	if code, body := opCall(t, e, tid, http.MethodPost, "/v1/operator/invites", "good",
		map[string]any{"tenant": tid, "email": "silent@example.com", "no_mail": true}); code != http.StatusCreated {
		t.Fatalf("no_mail: %d %v", code, body)
	}
	if len(sent) != mailsBefore {
		t.Fatalf("no_mail sent a mail: %v", sent)
	}

	// revoke, then revoke again -> 404
	rev := "/v1/operator/invites?tenant=" + tid + "&email=" + url.QueryEscape(pending)
	if code, _ := opCall(t, e, tid, http.MethodDelete, rev, "good", nil); code != http.StatusNoContent {
		t.Fatalf("revoke: %d", code)
	}
	if code, _ := opCall(t, e, tid, http.MethodDelete, rev, "good", nil); code != http.StatusNotFound {
		t.Fatalf("revoke gone: %d", code)
	}

	// CONTROLS: no token, a rejected token, and a verified identity that is not
	// on the operator allow-list.
	req := map[string]any{"tenant": tid, "email": "x@example.com"}
	if code, _ := opCall(t, e, tid, http.MethodPost, "/v1/operator/invites", "", req); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	if code, _ := opCall(t, e, tid, http.MethodPost, "/v1/operator/invites", "nope", req); code != http.StatusUnauthorized {
		t.Fatalf("bad token: %d", code)
	}
	if code, _ := opCall(t, e, tid, http.MethodPost, "/v1/operator/invites", "other-sa", req); code != http.StatusForbidden {
		t.Fatalf("non-operator identity: %d", code)
	}
	// a malformed invited_by is refused
	if code, _ := opCall(t, e, tid, http.MethodPost, "/v1/operator/invites", "good",
		map[string]any{"tenant": tid, "email": "y@example.com", "invited_by": "someone"}); code != http.StatusBadRequest {
		t.Fatalf("bad invited_by: %d", code)
	}
}

// CONTROL: with no operator config the routes answer 404 (a probe cannot tell
// a disabled hub from a missing path).
func TestOperatorRoutesDisabled(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	if code, _ := opCall(t, e, tid, http.MethodPost, "/v1/operator/invites", "good",
		map[string]any{"tenant": tid, "email": "x@example.com"}); code != http.StatusNotFound {
		t.Fatalf("disabled: %d", code)
	}
}
