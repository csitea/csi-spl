package action

import (
	"context"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// TestReactRefusals pins React's refusals verbatim: each one is returned
// before any hub call, so a nil Hub and an unreachable HubURL are never used.
func TestReactRefusals(t *testing.T) {
	const id = "11111111-1111-4111-8111-111111111111"
	hub := &config.Config{HubURL: "http://127.0.0.1:0"}
	for _, tc := range []struct {
		name string
		cfg  *config.Config
		in   ReactArgs
		want string
	}{
		{"no hub url", &config.Config{}, ReactArgs{TaskID: id, Emoji: "+1", As: "c-001"},
			"reacting needs hub mode ($SPOOL_HUB_URL is not set)"},
		{"bad msg", hub, ReactArgs{TaskID: id, MsgID: "not-a-uuid", Emoji: "+1", As: "c-001"},
			"--msg must be a message UUID"},
		{"bad task", hub, ReactArgs{TaskID: "not-a-uuid", Emoji: "+1", As: "c-001"},
			"--task must be the topic's task UUID (or give --msg)"},
		{"no task no msg", hub, ReactArgs{Emoji: "+1", As: "c-001"},
			"--task must be the topic's task UUID (or give --msg)"},
		{"no emoji", hub, ReactArgs{TaskID: id, Emoji: " ", As: "c-001"},
			"--emoji is required"},
		{"bad as", hub, ReactArgs{TaskID: id, Emoji: "+1", As: ""},
			"--as (the acting agent id) is required"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := React(context.Background(), tc.cfg, tc.in)
			if err == nil || err.Error() != tc.want {
				t.Fatalf("err = %v, want %q", err, tc.want)
			}
		})
	}
}
