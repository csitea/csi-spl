package spool

import (
	"sync"
	"testing"
)

// TestFR006_ConcurrentAckDeliversAtMostOnce: two `recv --ack` racing on one
// inbox. Only the process whose archive rename succeeded may return a message;
// the loser drops it silently and does not fail (FR-006, prompt.md section 5
// item 6). Before the fix the message was appended before the rename, so the
// loser returned it too and exited 1 (measured 37/200 with the CLI).
func TestFR006_ConcurrentAckDeliversAtMostOnce(t *testing.T) {
	const rounds, perRound = 200, 4
	cfg := newCfg(t)
	st := New(cfg)
	dup, failed := 0, 0
	for r := 0; r < rounds; r++ {
		for i := 0; i < perRound; i++ {
			if _, err := st.Send("GRK-03", "CLE-07", "", "task", "race", nil); err != nil {
				t.Fatal(err)
			}
		}
		var wg sync.WaitGroup
		var mu sync.Mutex
		seen := map[string]int{}
		for g := 0; g < 2; g++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				res, err := st.Recv("CLE-07", true)
				mu.Lock()
				defer mu.Unlock()
				if err != nil {
					failed++
				}
				if res != nil {
					for _, m := range res.Messages {
						seen[m.MsgID]++
					}
				}
			}()
		}
		wg.Wait()
		if len(seen) != perRound {
			t.Fatalf("round %d: %d distinct messages delivered, want %d", r, len(seen), perRound)
		}
		for _, n := range seen {
			if n > 1 {
				dup++
			}
		}
	}
	if dup != 0 || failed != 0 {
		t.Fatalf("n=%d rounds x %d msgs: %d delivered twice, %d recv calls failed; want 0 and 0", rounds, perRound, dup, failed)
	}
}
