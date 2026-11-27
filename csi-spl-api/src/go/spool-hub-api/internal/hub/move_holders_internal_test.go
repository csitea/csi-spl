package hub

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// rosterDown is a store whose roster read fails.
type rosterDown struct{ store.Store }

func (rosterDown) Roster(context.Context, string) (map[string][]string, error) {
	return nil, errors.New("roster down (test)")
}

// SPL-6700: a move notice went to every holder the hub could name, whether
// or not its box announced it now. A channel's invite row outlives a retired
// id, so the notice addressed to_box=box-a to=c-873 made that box's desk mint a
// seat for the retired c-873. Run on the code before the fix, the unannounced
// holders are listed and this goes red. CONTROL: the announced c-001 is kept,
// and a roster that cannot be read lists no one.
func TestMoveHoldersKeepsOnlyAnnouncedAgents(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemory()
	if err := st.SetRoster(ctx, "t1", "box-a", []string{"c-001"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	s := &Server{o: Options{Store: st, Log: zerolog.Nop()}}
	dm := func(to string, boxes ...string) store.EditableMessage {
		m := store.EditableMessage{MsgID: "m-" + to, TaskID: "a", ToID: to}
		for _, b := range boxes {
			m.Deliveries = append(m.Deliveries, store.ViewDelivery{ToBox: b, State: store.StateSent})
		}
		return m
	}
	if got := fmt.Sprint(s.moveHolders(ctx, "t1", dm("c-001", "box-a"))); got != "[[box-a c-001]]" {
		t.Errorf("CONTROL: announced c-001 holders = %s, want [[box-a c-001]]", got)
	}
	if got := s.moveHolders(ctx, "t1", dm("c-873", "box-a")); len(got) != 0 {
		t.Errorf("retired c-873 (not announced on box-a) holders = %v, want none", got)
	}
	if got := s.moveHolders(ctx, "t1", dm("c-001", "box-b")); len(got) != 0 {
		t.Errorf("c-001 on box-b, which does not announce it, holders = %v, want none", got)
	}
	down := &Server{o: Options{Store: rosterDown{st}, Log: zerolog.Nop()}}
	if got := down.moveHolders(ctx, "t1", dm("c-001", "box-a")); len(got) != 0 {
		t.Errorf("roster unreadable: holders = %v, want none", got)
	}
}
