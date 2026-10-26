package store

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// spec 140 3.10 (rdb 0229): the month of one workspace's burn. A minute
// keeps its WorkTenant, the rollup carries it to the day, and the read takes
// the days the minutes still hold from the minutes and older days from the
// rollup, each once. Memory and Postgres. RED CONTROL (n=1, in the commit):
// with the daily half reading every day of the month, yesterday (rolled up
// and still held as minutes) counts twice (21, not 18).
func TestWorkspaceTokenMonth(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	cut, _, _ := fleetTokenCuts(now)
	oldDay := cut.Add(-24 * time.Hour) // pruned to the rollup
	keep := cut.Add(24*time.Hour + 10*time.Hour)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ft, wt := st.(FleetTokenStore), st.(WorkspaceTokens)
			box, ws, op := strings.ToLower(uid("r")), strings.ToLower(uid("w")), strings.ToLower(uid("o"))
			at := func(s wire.FleetTokenSample, tenant string) wire.FleetTokenSample { s.WorkTenant = tenant; return s }
			if _, err := ft.RecordSamples(ctx, box, []wire.FleetTokenSample{
				at(fleetSample("c-1", "claude", "", oldDay.Add(10*time.Hour), 10, 0, 0, 0), ws),
				at(fleetSample("c-1", "claude", "", keep, 5, 0, 0, 0), ws),
				at(fleetSample("c-2", "claude", "", keep, 100, 0, 0, 0), ""),
				at(fleetSample("c-1", "claude", "", now.Truncate(24*time.Hour).Add(-14*time.Hour), 3, 0, 0, 0), ws), // yesterday: rolled and kept
				at(fleetSample("c-1", "claude", "", now.Truncate(time.Minute).Add(-time.Minute), 7, 0, 0, 0), ws),
			}); err != nil {
				t.Fatal(err)
			}
			if _, err := ft.PruneOldBuckets(ctx, now); err != nil {
				t.Fatal(err)
			}
			days, err := ft.ListDays(ctx, oldDay)
			if err != nil {
				t.Fatal(err)
			}
			rolled := false
			for _, d := range days {
				rolled = rolled || (d.BoxTag == box && d.Day.Equal(oldDay) && d.WorkTenant == ws && d.TokensIn == 10)
			}
			if !rolled {
				t.Fatalf("the pruned day's rollup lost its workspace: %+v", days)
			}
			q := WorkspaceTokenQuery{Operator: op, Workspace: ws, From: oldDay.Format(time.DateOnly),
				To: oldDay.Add(31 * 24 * time.Hour).Format(time.DateOnly), Now: now}
			got, err := wt.WorkspaceTokenMonth(ctx, q)
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != 1 || got[0] != (WorkspaceTokenPart{Workspace: ws, Vendor: "claude", Tokens: 18, Days: 3}) {
				t.Fatalf("workspace %s: %+v, want claude 18 tokens on 3 days (the pruned day's rollup 10, the kept minute's 5, yesterday's 3 once; today is past To)", ws, got)
			}
			q.Workspace = ""
			all, err := wt.WorkspaceTokenMonth(ctx, q)
			if err != nil {
				t.Fatal(err)
			}
			mine := map[string]int64{}
			for _, p := range all {
				mine[p.Workspace] += p.Tokens
			}
			if mine[ws] != 18 || mine[op] < 100 {
				t.Fatalf("every workspace: %v, want %s 18 and the operator's own (NULL) rows as %s >= 100", mine, ws, op)
			}
			for _, bad := range []WorkspaceTokenQuery{{Workspace: ws, From: q.From, To: q.To}, {Operator: op, Workspace: "Bad Id", From: q.From, To: q.To},
				{Operator: op, From: q.From, To: oldDay.Add(40 * 24 * time.Hour).Format(time.DateOnly)}} {
				if _, err := wt.WorkspaceTokenMonth(ctx, bad); err == nil {
					t.Errorf("%+v: no error", bad)
				}
			}
		})
	}
}
