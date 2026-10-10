package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 121 T302, end to end over the box socket: the recv frame names its
// turn; a reply that names the turn with the model's usage record writes the
// priced rows; a reply that names it without one (or with a model nobody
// priced) is written unmetered and leaves the alert line, and never reads as
// zero; a reply from an older box names no turn and meters nothing; a turn
// the hub never delivered meters nothing. Memory, and Postgres under
// SPOOL_TEST_PG_DSN.
func TestMeteringTurns(t *testing.T) {
	logs := &lockedBuf{}
	e := newEnv(t, func(o *hub.Options) { o.Log = zerolog.New(logs) })
	tid, _ := e.tenant()
	ctx := context.Background()
	b := e.box(tid, "box-b", "CLE-08")
	c := e.box(tid, "box-c", "CLE-09")
	e.pin(tid, b)
	e.pin(tid, c)
	ul, ok := e.st.(store.UsageLedger)
	if !ok {
		t.Fatalf("%T has no usage ledger", e.st)
	}
	model := "m-" + uuidV4()[:8]
	at := time.Now().Add(-time.Hour)
	for kind, micros := range map[string]int64{store.UsageKindIn: 3_000_000, store.UsageKindOut: 15_000_000} {
		putModelPrice(t, e.st, store.ModelPrice{Provider: "anthropic", Model: model, Kind: kind, MicrosPerMillion: micros, Currency: "EUR", ValidFrom: at})
	}

	seat := e.rawBox(tid, c, []string{"CLE-09"}, nil)
	ask := func() string {
		id := send(t, b, "CLE-08", "CLE-09", "task", "a question", "box-c").MsgID
		if f := seat.next(wire.TRecv); f.TurnID != id {
			t.Fatalf("the recv frame names turn %q, want the delivered msg_id %s", f.TurnID, id)
		}
		return id
	}
	cli, err := c.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { closeWait(cli) })
	reply := func(cl hubclient.Claims) {
		t.Helper()
		env := signedIn(t, c, "box-b", "", "", &msg.Message{V: 1, MsgID: uuidV4(), TaskID: uuidV4(),
			TS: time.Now().UTC().Format(time.RFC3339), From: "CLE-09", To: "CLE-08", Kind: "result",
			Body: "the answer", Files: []msg.Attachment{}})
		if _, err := cli.SendClaims(ctx, env, cl); err != nil {
			t.Fatalf("a metering claim failed the send: %v", err)
		}
	}
	ledger := func(turn string) store.TurnLedger {
		t.Helper()
		l, err := ul.TurnLedger(ctx, tid, turn+":CLE-09")
		if err != nil {
			t.Fatal(err)
		}
		return l
	}
	alerts := func() int {
		n := 0
		for _, l := range logs.lines(t) {
			if l["alert"] == "usage_unmetered" {
				n++
			}
		}
		return n
	}

	// reported: priced rows, no alert
	q1 := ask()
	reply(hubclient.Claims{TurnID: q1, Usage: &wire.UsageReport{TurnID: q1, Provider: "anthropic", Model: model, TokensIn: 1000, TokensOut: 200}})
	if l := ledger(q1); !l.Metered() || l.Tokens != 1200 || l.CostMicros != "6000.000000" || l.Currency != "EUR" {
		t.Errorf("a reported turn reads %+v, want metered 1200 tokens, 6000 EUR micros", l)
	}
	if n := alerts(); n != 0 {
		t.Errorf("a reported turn alerted %d times", n)
	}

	// no report: unmetered, alerted, never zero
	q2 := ask()
	reply(hubclient.Claims{TurnID: q2})
	if l := ledger(q2); l.Metered() || !l.Unmetered || l.Rows != 1 {
		t.Errorf("a turn without a report reads %+v, want one unmetered row, NOT metered", l)
	}
	if n := alerts(); n != 1 {
		t.Errorf("a turn without a report alerted %d times, want 1", n)
	}

	// a model nobody priced: unmetered, alerted
	q3 := ask()
	reply(hubclient.Claims{TurnID: q3, Usage: &wire.UsageReport{TurnID: q3, Provider: "anthropic", Model: "unpriced-" + model, TokensIn: 5}})
	if l := ledger(q3); l.Metered() || !l.Unmetered {
		t.Errorf("an unpriced report reads %+v, want unmetered", l)
	}
	// a report that names another turn than the frame: unmetered
	q4 := ask()
	reply(hubclient.Claims{TurnID: q4, Usage: &wire.UsageReport{TurnID: q1, Provider: "anthropic", Model: model}})
	if l := ledger(q4); !l.Unmetered {
		t.Errorf("a report of another turn reads %+v, want unmetered", l)
	}
	if n := alerts(); n != 3 {
		t.Errorf("alerts = %d, want 3", n)
	}

	// an older box names no turn: the send passes, nothing is metered
	q5 := ask()
	reply(hubclient.Claims{})
	if l := ledger(q5); l.Rows != 0 {
		t.Errorf("an older box's reply wrote %+v", l)
	}
	// a turn the hub never delivered here: nothing metered, no alert
	ghost := uuidV4()
	reply(hubclient.Claims{TurnID: ghost})
	if l := ledger(ghost); l.Rows != 0 {
		t.Errorf("an unknown turn wrote %+v", l)
	}
	if n := alerts(); n != 3 {
		t.Errorf("alerts after the older box and the unknown turn = %d, want 3", n)
	}
}

// putModelPrice writes a price on either driver; on Postgres only the
// operator scope may.
func putModelPrice(t *testing.T, st store.Store, p store.ModelPrice) {
	t.Helper()
	switch d := st.(type) {
	case *store.Memory:
		d.PutModelPrice(p)
	case *store.Postgres:
		ctx := context.Background()
		if err := pgx.BeginFunc(ctx, d.Pool(), func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO model_prices (provider, model, kind, micros_per_million, currency, valid_from)
				VALUES ($1, $2, $3, $4, $5, $6)`, p.Provider, p.Model, p.Kind, p.MicrosPerMillion, p.Currency, p.ValidFrom)
			return err
		}); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("no price seam for %T", st)
	}
}
