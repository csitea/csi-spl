package action

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// askListPages caps the pages one list reads: 4000 x 256 KiB is ~1 GB.
const askListPages = 4000

// askListAll is a list read page by page (SPL-4018): the whole book in one
// frame crossed the CLI's 1 MiB read limit on prd (1644 asks, ~1.56 MB) and
// the socket closed. It asks the hub for pages and follows next until the
// last; a hub without paging answers the whole book with no next, as before.
// A row answered twice (it closed between two pages) keeps its later copy.
// The answer is the hub's first page with every page's asks and no next.
func askListAll(ctx context.Context, hc *hubclient.Client, fleet string, body json.RawMessage) (json.RawMessage, error) {
	var req map[string]any
	if err := json.Unmarshal(body, &req); err != nil {
		return nil, err
	}
	req["page"] = true
	var head map[string]json.RawMessage
	rows, at := []json.RawMessage{}, map[string]int{}
	for n := 0; n < askListPages; n++ {
		page, err := askListPage(ctx, hc, fleet, req)
		if err != nil {
			return nil, err
		}
		if head == nil {
			head = page.head
		}
		for _, r := range page.asks {
			rows = keepLastAsk(rows, at, r)
		}
		if page.next == "" {
			head["asks"], _ = json.Marshal(compactAsks(rows))
			delete(head, "next")
			return json.Marshal(head)
		}
		if page.next == req["after"] {
			return nil, fmt.Errorf("ask list: the hub answered the same page twice (next %q)", page.next)
		}
		req["after"] = page.next
	}
	return nil, fmt.Errorf("ask list: more than %d pages", askListPages)
}

type askListAnswer struct {
	head map[string]json.RawMessage
	asks []json.RawMessage
	next string
}

func askListPage(ctx context.Context, hc *hubclient.Client, fleet string, req map[string]any) (askListAnswer, error) {
	b, err := json.Marshal(req)
	if err != nil {
		return askListAnswer{}, err
	}
	raw, err := hc.Ask(ctx, "list", fleet, b)
	if err != nil {
		return askListAnswer{}, err
	}
	var out askListAnswer
	if err := json.Unmarshal(raw, &out.head); err != nil {
		return askListAnswer{}, fmt.Errorf("ask list: the hub's answer does not decode: %w", err)
	}
	if a := out.head["asks"]; len(a) > 0 {
		if err := json.Unmarshal(a, &out.asks); err != nil {
			return askListAnswer{}, fmt.Errorf("ask list: asks do not decode: %w", err)
		}
	}
	if n := out.head["next"]; len(n) > 0 {
		if err := json.Unmarshal(n, &out.next); err != nil {
			return askListAnswer{}, fmt.Errorf("ask list: next does not decode: %w", err)
		}
	}
	return out, nil
}

// keepLastAsk appends r, blanking an earlier copy of the same ask_id.
func keepLastAsk(rows []json.RawMessage, at map[string]int, r json.RawMessage) []json.RawMessage {
	var id struct {
		AskID string `json:"ask_id"`
	}
	if json.Unmarshal(r, &id) == nil && id.AskID != "" {
		if i, ok := at[id.AskID]; ok {
			rows[i] = nil
		}
		at[id.AskID] = len(rows)
	}
	return append(rows, r)
}

func compactAsks(rows []json.RawMessage) []json.RawMessage {
	out := []json.RawMessage{}
	for _, r := range rows {
		if r != nil {
			out = append(out, r)
		}
	}
	return out
}
