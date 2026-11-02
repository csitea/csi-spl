package hub_test

import (
	"bytes"
	"encoding/json"
	"flag"
	"maps"
	"net/http"
	"os"
	"testing"
)

var updateContactsAnswers = flag.Bool("update-contacts-answers", false, "rewrite testdata/contacts_answers.golden.json")

const contactsAnswersGolden = "testdata/contacts_answers.golden.json"

// contactsAnswer is one route's real answer, as the browser reads it.
type contactsAnswer struct {
	Status int `json:"status"`
	Body   any `json:"body"`
}

// contactsMasked is a copy of the answer without what differs per run: ids,
// clocks and the rig's random member address. The keys and the nesting stay,
// they are the point.
func contactsMasked(c *contactsRig, out map[string]any) map[string]any {
	row := maps.Clone(out)
	for key, mask := range map[string]string{"contact_id": "<contact_id>", "created_at": "<time>", "updated_at": "<time>", "member_id": "<member_id>"} {
		if row[key] != nil {
			row[key] = mask
		}
	}
	if row["email"] == c.email {
		row["email"] = "member@example.com"
	}
	return row
}

// SPL-4661: the hub's answers on the contacts routes, pinned for the web
// client. csi-spl-wui/tests/unit/contacts-client.test.mjs feeds this file
// through contacts-client.mjs, so a client that reads another shape and a hub
// that changes its shape both go red, without a browser. It is generated from
// the handlers on the rig's store, never written by hand: memory, or Postgres
// under SPOOL_TEST_PG_DSN, and both answer this file:
//
//	go test ./internal/hub -run TestContactsAnswersGolden -update-contacts-answers
func TestContactsAnswersGolden(t *testing.T) {
	c := newContactsRig(t, onAll)
	answers := map[string]contactsAnswer{}
	ask := func(name, method, path string, body any) map[string]any {
		t.Helper()
		code, raw, out := c.do(t, c.b1, method, path, body, nil)
		answers[name] = contactsAnswer{Status: code}
		if len(raw) > 0 {
			answers[name] = contactsAnswer{Status: code, Body: contactsMasked(c, out)}
		}
		return out
	}

	row := ask("create", http.MethodPost, contactsBase, map[string]any{"first_name": ctFirst, "last_name": ctLast, "email": ctEmail, "phone": ctPhone})
	id, _ := row["contact_id"].(string)
	if id == "" {
		t.Fatalf("CONTROL: POST answered no contact_id: %v", row)
	}
	one := contactsBase + "/" + id
	ask("get", http.MethodGet, one, nil)
	ask("patch", http.MethodPatch, one, map[string]any{"first_name": "Changed", "last_name": ctLast, "email": ctEmail, "phone": ctPhone})
	ask("patch_email_null", http.MethodPatch, one, map[string]any{"email": nil})
	ask("patch_email_empty", http.MethodPatch, one, map[string]any{"email": ""})
	ask("patch_phone_empty", http.MethodPatch, one, map[string]any{"phone": ""})
	ask("patch_first_empty", http.MethodPatch, one, map[string]any{"first_name": ""})
	ask("patch_last_empty", http.MethodPatch, one, map[string]any{"first_name": "Changed", "last_name": ""})
	ask("refused_all_empty", http.MethodPatch, one, map[string]any{"first_name": "", "last_name": "", "email": "", "phone": ""})
	ask("refused_bad_email", http.MethodPost, contactsBase, map[string]any{"email": "no-at-sign"})
	ask("delete", http.MethodDelete, one, nil)
	ask("get_deleted", http.MethodGet, one, nil)

	// A contact of a member: the card names the member, a patch's answer does not.
	mine := ask("member_create", http.MethodPost, contactsBase, map[string]any{"email": c.email})
	mineID, _ := mine["contact_id"].(string)
	got := ask("member_get", http.MethodGet, contactsBase+"/"+mineID, nil)
	if got["member_id"] == nil {
		t.Fatalf("CONTROL: the card of a member's contact has no member_id: %v", got)
	}
	ask("member_patch", http.MethodPatch, contactsBase+"/"+mineID, map[string]any{"first_name": ctFirst})

	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetIndent("", "  ")
	if err := enc.Encode(answers); err != nil {
		t.Fatal(err)
	}
	if *updateContactsAnswers {
		if err := os.WriteFile(contactsAnswersGolden, buf.Bytes(), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(contactsAnswersGolden)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(buf.Bytes(), want) {
		t.Errorf("the hub's contacts answers changed; the web client reads %s (csi-spl-wui/src/utils/contacts-client.mjs). Got:\n%s", contactsAnswersGolden, buf.String())
	}
}
