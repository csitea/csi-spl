package hub_test

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/i18n"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The cost labels' machine drafts (SPL-6173, spec 123 16.6.7 row L3). Every
// name, text and token here is synthetic.

const (
	costLabelsFill       = "/v1/operator/cost-labels/fill"
	costLabelsUnreviewed = "/v1/operator/cost-labels/unreviewed"
	costLabelsReviewed   = "/v1/operator/cost-labels/reviewed"
	// plantedName is the hr person's name a label carries: it must never
	// reach the API stub.
	plantedName = "Testi Kuvitteellinen"
)

// stubTranslator is the API: it records every content it is sent and
// answers "<locale>: <content>", or an error while fail is set or when the
// content lacks only (so a fill on a shared database drafts no other test's
// text or component).
type stubTranslator struct {
	mu    sync.Mutex
	sent  []string
	fail  bool
	only  string
	calls int
}

func (s *stubTranslator) Translate(_ context.Context, content, _, target string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	s.sent = append(s.sent, content)
	if s.fail || !strings.Contains(content, s.only) {
		return "", errors.New("stub: 503")
	}
	return target + ": " + content, nil
}

func (s *stubTranslator) Reserve(int) bool { return true }

func (s *stubTranslator) set(fail bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fail = fail
}

// sentWith is every content sent so far that holds sub.
func (s *stubTranslator) sentWith(sub string) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.DeleteFunc(slices.Clone(s.sent), func(c string) bool { return !strings.Contains(c, sub) })
}

// machineRig is the fleet tokens rig with the stub API and the operator
// service account (token "good").
func machineRig(t *testing.T) (*fleetTokensRig, *stubTranslator) {
	t.Helper()
	tr := &stubTranslator{}
	r := newFleetTokensRig(t, func(o *hub.Options) {
		o.CostLabelTranslator = tr
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			if token == "good" {
				return operatorSA, nil
			}
			return "", errors.New("token rejected")
		}
	})
	return r, tr
}

// plantPerson stores an hr person named plantedName (a free code).
func plantPerson(t *testing.T, r *fleetTokensRig) {
	t.Helper()
	hr := r.e.st.(store.HRCostStore)
	for range 20 {
		n, _ := rand.Int(rand.Reader, big.NewInt(10000))
		code := fmt.Sprintf("ZQ-%04d", n.Int64())
		_, err := hr.CreateHRPerson(context.Background(), store.HRPerson{Code: code, Name: plantedName, EmploymentType: "employee", CreatedBy: "test"})
		if err == nil {
			return
		}
		if !errors.Is(err, store.ErrConflict) {
			t.Fatal(err)
		}
	}
	t.Fatal("no free hr person code")
}

// newCloudEntry posts a cloud entry with text and answers its id.
func newCloudEntry(t *testing.T, r *fleetTokensRig, text string) string {
	t.Helper()
	code, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, r.admin,
		map[string]any{"type": "cloud", "label": text, "amount": 12, "currency": "EUR", "period": "2004-02"})
	id, _ := got["id"].(string)
	if code != http.StatusCreated || id == "" {
		t.Fatalf("create %q: %d %v, want 201", text, code, got)
	}
	t.Cleanup(func() { call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, r.admin, nil) })
	return id
}

// entryLabels is entry id's labels and label_origins on the list.
func entryLabels(t *testing.T, r *fleetTokensRig, id string) (map[string]any, map[string]any) {
	t.Helper()
	code, got := call(t, r.e, r.op, http.MethodGet, costEntryPath+"?type=cloud&month=2004-02", r.admin, nil)
	if code != http.StatusOK {
		t.Fatalf("list: %d %v", code, got)
	}
	for _, e := range got["entries"].([]any) {
		if m := e.(map[string]any); m["id"] == id {
			labels, _ := m["labels"].(map[string]any)
			origins, _ := m["label_origins"].(map[string]any)
			if _, ok := m["stale_locales"].([]any); !ok {
				t.Errorf("stale_locales is not a list: %v", m["stale_locales"])
			}
			return labels, origins
		}
	}
	t.Fatalf("no entry %s on the list", id)
	return nil, nil
}

// A new text lands with 18 machine rows beside its hand master row and the
// POST answers 201; the API stub's input holds [NAME_1] and never the
// planted hr name. RED CONTROL: a draft that sends the text unmasked fails
// the planted-name assertion.
func TestCostLabelsDraftOnSave(t *testing.T) {
	r, tr := machineRig(t)
	plantPerson(t, r)
	uniq := newTenantID("lbl")
	text := "Laptop for " + plantedName + " " + uniq
	id := newCloudEntry(t, r, text)
	labels, origins := entryLabels(t, r, id)
	machine := 0
	for loc, o := range origins {
		if o == store.CostLabelMachine {
			machine++
		} else if loc != "en" {
			t.Errorf("%s: origin %v, want machine", loc, o)
		}
	}
	if len(labels) != len(i18n.Supported) || machine != len(i18n.Supported)-1 || origins["en"] != store.CostLabelHand {
		t.Fatalf("labels %d, machine %d, en %v: want 19 rows, 18 machine, en hand", len(labels), machine, origins["en"])
	}
	if fi, _ := labels["fi"].(string); fi != "fi: Laptop for "+plantedName+" "+uniq {
		t.Errorf("the fi row: %q, want the stub's answer unmasked", fi)
	}
	sent := tr.sentWith(uniq)
	if len(sent) != len(i18n.Supported)-1 {
		t.Fatalf("the stub got %d calls for the text, want 18", len(sent))
	}
	for _, c := range sent {
		if strings.Contains(strings.ToLower(c), "kuvitteellinen") || strings.Contains(strings.ToLower(c), "testi") {
			t.Fatalf("the API stub received the planted name: %q", c)
		}
		if !strings.Contains(c, `<span translate="no">[NAME_1]</span>`) {
			t.Errorf("the API stub's input lacks the [NAME_1] span: %q", c)
		}
	}
	// a known text is copied on the save: no call
	before := tr.calls
	id2 := newCloudEntry(t, r, text)
	if l2, _ := entryLabels(t, r, id2); len(l2) != len(i18n.Supported) || tr.calls != before {
		t.Errorf("a known text: %d rows, %d new calls, want 19 rows and no call", len(l2), tr.calls-before)
	}
}

// A stub error leaves the save (201) and its one master row; the fill route
// then drafts the missing text (the night run's first step).
func TestCostLabelsStubErrorThenFill(t *testing.T) {
	r, tr := machineRig(t)
	tr.set(true)
	uniq := newTenantID("lbl")
	tr.only = uniq
	text := "Backup storage " + uniq
	id := newCloudEntry(t, r, text)
	if labels, _ := entryLabels(t, r, id); len(labels) != 1 {
		t.Fatalf("after a stub error: %d rows %v, want the master row alone", len(labels), labels)
	}
	tr.set(false)
	code, got := opCall(t, r.e, r.op, http.MethodPost, costLabelsFill, "good", nil)
	if code != http.StatusOK || got["written"] == nil {
		t.Fatalf("fill: %d %v", code, got)
	}
	if labels, _ := entryLabels(t, r, id); len(labels) != len(i18n.Supported) {
		t.Errorf("after the fill: %d rows, want 19", len(labels))
	}
}

// The unreviewed read hands out the masked text and drafts and nothing else
// (no amount, period, person or entry id); a PUT with another source_sha is
// 409 stale_source; the right one writes the row reviewed, unmasked.
// RED CONTROL: an item carrying an amount field fails the key-set check.
func TestCostLabelsReviewRoundTrip(t *testing.T) {
	r, _ := machineRig(t)
	plantPerson(t, r)
	uniq := newTenantID("lbl")
	id := newCloudEntry(t, r, "Travel "+plantedName+" "+uniq)
	code, got := opCall(t, r.e, r.op, http.MethodGet, costLabelsUnreviewed, "good", nil)
	if code != http.StatusOK {
		t.Fatalf("unreviewed: %d %v", code, got)
	}
	var item map[string]any
	for _, it := range got["items"].([]any) {
		m := it.(map[string]any)
		keys := slices.Sorted(func(yield func(string) bool) {
			for k := range m {
				if !yield(k) {
					return
				}
			}
		})
		if strings.Join(keys, ",") != "key,masked_drafts,masked_text,source_sha" {
			t.Fatalf("an unreviewed item carries %v, want key, source_sha, masked_text, masked_drafts only", keys)
		}
		if strings.Contains(m["masked_text"].(string), uniq) {
			item = m
		}
	}
	if item == nil || item["masked_text"] != "Travel [NAME_1] "+uniq {
		t.Fatalf("the text's item: %v", item)
	}
	drafts := item["masked_drafts"].(map[string]any)
	if d, _ := drafts["fi"].(string); d != "fi: Travel [NAME_1] "+uniq {
		t.Errorf("the fi draft masked: %q", d)
	}
	body := map[string]any{"key": item["key"], "source_sha": "0000", "labels": map[string]string{"fi": "Matka [NAME_1] " + uniq}}
	if code, got := opCall(t, r.e, r.op, http.MethodPut, costLabelsReviewed, "good", body); code != http.StatusConflict || got["error"] != "stale_source" {
		t.Errorf("another source_sha: %d %v, want 409 stale_source", code, got)
	}
	body["source_sha"] = item["source_sha"]
	if code, got := opCall(t, r.e, r.op, http.MethodPut, costLabelsReviewed, "good", body); code != http.StatusOK || got["written"].(float64) < 1 {
		t.Fatalf("reviewed: %d %v", code, got)
	}
	labels, origins := entryLabels(t, r, id)
	if labels["fi"] != "Matka "+plantedName+" "+uniq || origins["fi"] != store.CostLabelReviewed || origins["sv"] != store.CostLabelMachine {
		t.Errorf("after the review: fi %v (%v), sv %v", labels["fi"], origins["fi"], origins["sv"])
	}
}

// An accountant member of the operator workspace (costs.write) reads 403 on
// the three new routes; the operator admin's session is refused the
// reviewed write, which is the service account's alone.
func TestCostLabelsMachineDoors(t *testing.T) {
	r, _ := machineRig(t)
	acc := seat(t, r.e, r.op, rbac.InternalAccountant)
	for _, rt := range [][2]string{{http.MethodPost, costLabelsFill}, {http.MethodGet, costLabelsUnreviewed}, {http.MethodPut, costLabelsReviewed}} {
		var body any
		if rt[0] == http.MethodPut {
			body = map[string]any{"key": "t:x", "source_sha": "x", "labels": map[string]string{}}
		}
		if code, got := call(t, r.e, r.op, rt[0], rt[1], acc, body); code != http.StatusForbidden {
			t.Errorf("accountant %s %s: %d %v, want 403", rt[0], rt[1], code, got)
		}
	}
	if code, got := call(t, r.e, r.op, http.MethodPut, costLabelsReviewed, r.admin, map[string]any{"key": "t:x", "source_sha": "x", "labels": map[string]string{}}); code != http.StatusForbidden {
		t.Errorf("the admin's session on reviewed: %d %v, want 403", code, got)
	}
	if code, got := call(t, r.e, r.op, http.MethodGet, costLabelsUnreviewed, r.admin, nil); code != http.StatusOK {
		t.Errorf("CONTROL the admin reads unreviewed: %d %v, want 200", code, got)
	}
}
