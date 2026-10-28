package action

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// pagedFleet routes a list to pagedAsk in the verb hub: fleet "paged" pages
// a b c (b again, closed, on the last page), "paged-loop" answers the same
// next forever, "paged-bad" answers asks that do not decode.
const pagedFleet = "paged"

func pagedAsk(f wire.Frame) wire.Frame {
	var in struct {
		Page  bool   `json:"page"`
		After string `json:"after"`
	}
	json.Unmarshal(f.Ask, &in) //nolint:errcheck
	ans := func(s string) wire.Frame {
		return wire.Frame{Type: wire.TAsk, MsgID: f.MsgID, Fleet: f.Fleet, Ask: json.RawMessage(s)}
	}
	switch {
	case !in.Page:
		return wire.Frame{Type: wire.TError, Error: "bad_frame", Status: http.StatusBadRequest, Detail: "no page"}
	case f.Fleet == "paged-loop":
		return ans(`{"fleet":"paged-loop","asks":[],"next":"0.1.x"}`)
	case f.Fleet == "paged-bad":
		return ans(`{"fleet":"paged-bad","asks":{"no":1}}`)
	case in.After == "":
		return ans(`{"fleet":"paged","created":false,"asks":[{"ask_id":"a","state":"open"},{"ask_id":"b","state":"open"}],"next":"0.2.b"}`)
	case in.After == "0.2.b":
		return ans(`{"fleet":"paged","created":false,"asks":[{"ask_id":"c","state":"done"}],"next":"1.3.c"}`)
	}
	return ans(`{"fleet":"paged","created":false,"asks":[{"ask_id":"b","state":"done"}]}`)
}

// SPL-4018: a list follows every page and answers one book with no next; a
// row answered twice keeps its later copy. RED CONTROL (Ask without
// askListAll, origin/master): "hub refused: bad_frame (no page)".
func TestAskListFollowsPages(t *testing.T) {
	cfg := hubCfg(t, newVerbHub(t))
	raw, err := Ask(context.Background(), cfg, AskArgs{Fleet: "paged", Role: "orch", All: true})
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	var got struct {
		Fleet string `json:"fleet"`
		Next  string `json:"next"`
		Asks  []struct {
			AskID string `json:"ask_id"`
			State string `json:"state"`
		} `json:"asks"`
	}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("answer %s: %v", raw, err)
	}
	var ids []string
	for _, a := range got.Asks {
		ids = append(ids, a.AskID+"="+a.State)
	}
	if got.Fleet != "paged" || got.Next != "" || strings.Join(ids, " ") != "a=open c=done b=done" {
		t.Fatalf("merged book: %s", raw)
	}
	for fleet, want := range map[string]string{"paged-loop": "same page twice", "paged-bad": "asks do not decode"} {
		if _, err := Ask(context.Background(), cfg, AskArgs{Fleet: fleet, All: true}); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v, want %q", fleet, err, want)
		}
	}
}
