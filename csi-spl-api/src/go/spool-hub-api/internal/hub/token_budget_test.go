package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 121 T304, end to end over the browser socket: a workspace's daily
// token budget against the T302 ledger. Under 80 % a turn is dispatched and
// nobody is told; at 80 % the biz_owner's socket gets ONE token_budget
// notice (and the alert line), a later turn in the same day none; at 100 %
// the next turn answers 429 token_quota before anything is built: no
// stored message, no queued delivery (no seat starts), no usage row. A
// resend of a stored turn still acks; a soft budget dispatches past 100 %.
// RED CONTROL: remove the tokenBudget call in wuiSend and the 100 % turn is
// queued (this test fails). Postgres only (Memory holds no budgets).
func TestTokenBudgetTurns(t *testing.T) {
	logs := &lockedBuf{}
	pub, key, _ := ed25519.GenerateKey(nil)
	e, _ := demoEnv(t, func(o *hub.Options) { o.WUIKey = key; o.Log = zerolog.New(logs) })
	tb, ok := e.st.(store.TokenBudgets)
	if !ok {
		t.Skip("token budgets are Postgres only; set SPOOL_TEST_PG_DSN")
	}
	ul := e.st.(store.UsageLedger)
	ctx := context.Background()
	tid, _ := e.tenant()
	e.pin(tid, e.box(tid, "box-a", "CLE-07"))
	e.pinKey(tid, hub.WUIBox, pub)
	model := "m-" + uuidV4()[:8]
	for _, kind := range []string{store.UsageKindIn, store.UsageKindOut} {
		putModelPrice(t, e.st, store.ModelPrice{Provider: "anthropic", Model: model, Kind: kind,
			MicrosPerMillion: 1_000_000, Currency: "EUR", ValidFrom: time.Now().Add(-48 * time.Hour)})
	}
	used := func(n int64) { // n more tokens in today's ledger
		t.Helper()
		if _, err := ul.MeterTurn(ctx, tid, store.TurnUsage{TurnRef: store.TurnRef{TurnID: uuidV4(), AgentID: "CLE-07",
			At: time.Now().Add(-time.Second)}, Provider: "anthropic", Model: model, TokensIn: n}); err != nil {
			t.Fatal(err)
		}
	}
	dayTokens := func() int64 {
		t.Helper()
		u, err := tb.BudgetUses(ctx, tid, "", time.Now())
		if err != nil || len(u) != 1 {
			t.Fatalf("BudgetUses = %+v, %v", u, err)
		}
		return u[0].DayTokens
	}
	alerts := func() int {
		n := 0
		for _, l := range logs.lines(t) {
			if l["alert"] == "token_budget_low" {
				n++
			}
		}
		return n
	}
	if _, err := tb.PutTokenBudget(ctx, tid, store.TokenBudget{TokensPerDay: ptr64(1000)}); err != nil {
		t.Fatal(err)
	}
	owner := dialMember(t, e, tid, "", seat(t, e, tid, rbac.BizOwner))
	dev := dialMember(t, e, tid, "", seat(t, e, tid, rbac.Developer))
	turn := func() (string, map[string]any) {
		id := uuidV4()
		wsjson.Write(ctx, dev, map[string]any{"type": "send", "msg_id": id, "task_id": "lobby", //nolint:errcheck
			"kind": "task", "body": "@CLE-07 a turn"})
		return id, readType(t, dev, "ack")
	}
	dispatched := func(id string, f map[string]any) {
		t.Helper()
		if f["type"] != "ack" || f["to_box"] != "box-a" || f["delivery"] != wire.DeliveryQueued {
			t.Fatalf("turn %s: %v, want a queued dispatch", id, f)
		}
	}

	used(700) // 70 %: dispatched, no notice
	id, f := turn()
	dispatched(id, f)
	if n := alerts(); n != 0 {
		t.Fatalf("a turn at 70 %% alerted %d times", n)
	}

	used(150) // 85 %: dispatched, the one notice
	id, f = turn()
	dispatched(id, f)
	if nf := readType(t, owner, "token_budget"); nf["level"] != "low" || nf["limit"] != store.BudgetLimitDay ||
		nf["pct"] != float64(85) || nf["hard_stop"] != true {
		t.Fatalf("owner notice at 85 %%: %v", nf)
	}
	stored, f := turn()
	dispatched(stored, f)
	if n := alerts(); n != 1 {
		t.Fatalf("alerts after two turns over 80 %% = %d, want ONE notice", n)
	}

	used(200) // 105 %: refused before anything is built
	before := dayTokens()
	refused, f := turn()
	if f["type"] != "error" || f["error"] != "token_quota" || f["status"] != float64(http.StatusTooManyRequests) {
		t.Fatalf("turn at 105 %%: %v, want 429 token_quota", f)
	}
	if q := queued(t, e, tid); q[refused] || len(q) != 3 {
		t.Fatalf("box-a queue after the refusal: %d rows, refused turn queued %v; want 3, no seat started", len(q), q[refused])
	}
	if _, _, err := e.st.MessageTimes(ctx, tid, refused); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("refused turn stored: %v", err)
	}
	if l, err := ul.TurnLedger(ctx, tid, refused+":CLE-07"); err != nil || l.Rows != 0 {
		t.Fatalf("refused turn ledger %+v, %v; want no usage row", l, err)
	}
	if n := dayTokens(); n != before {
		t.Fatalf("the refusal moved the ledger %d -> %d", before, n)
	}
	if n := alerts(); n != 1 {
		t.Fatalf("alerts after the refusal = %d, want still 1 (same day)", n)
	}

	// A resend of a stored turn is no new turn: it re-acks.
	wsjson.Write(ctx, dev, map[string]any{"type": "send", "msg_id": stored, "task_id": "lobby", //nolint:errcheck
		"kind": "task", "body": "@CLE-07 a turn"})
	if f := readType(t, dev, "ack"); f["type"] != "ack" {
		t.Fatalf("resend of a stored turn over budget: %v", f)
	}

	// A soft budget (the owner's approved customer) dispatches past 100 %.
	if _, err := tb.PutTokenBudget(ctx, tid, store.TokenBudget{TokensPerDay: ptr64(1000), Soft: true}); err != nil {
		t.Fatal(err)
	}
	id, f = turn()
	dispatched(id, f)
	expectNoFrame(t, owner, "token_budget")
}

func ptr64(n int64) *int64 { return &n }

// expectNoFrame fails when c holds a frame of type want within a short wait.
func expectNoFrame(t *testing.T, c *websocket.Conn, want string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	for {
		var f map[string]any
		if err := wsjson.Read(ctx, c, &f); err != nil {
			return
		}
		if f["type"] == want {
			t.Fatalf("unexpected %s frame: %v", want, f)
		}
	}
}
