package hub_test

import (
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// t1 8fb802cd (owner: "If a topic is archived it should be clearly marked
// as archived"). Every list leaves an archived topic out, but a topic read by
// its id still answers - a link, a notification, the Archive view - and the
// answer said nothing about the archive, so the WUI drew it as a live topic.
// The read now carries the topic's archive stamp; a live topic carries none.
func TestTopicReadCarriesArchiveStamp(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC()
	T, L := uuidV4(), uuidV4()
	card := putCard(t, e, tid, T, "", "HUM-1", hub.WUIBox, 1, now)
	putCard(t, e, tid, T, "", "HUM-2", hub.WUIBox, 0, now.Add(time.Second))
	putCard(t, e, tid, L, "", "HUM-1", hub.WUIBox, 1, now.Add(2*time.Second))

	read := func(task, query string) map[string]any {
		t.Helper()
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+task+query, "HUM-2", nil)
		if code != http.StatusOK {
			t.Fatalf("read %s%s: %d %v", task, query, code, out)
		}
		return out
	}
	if out := read(T, ""); out["archived_at"] != nil || out["archived_by"] != nil {
		t.Fatalf("a live topic carries an archive stamp: %v", out)
	}
	if code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+card+"/archive", "HUM-1", nil); code != http.StatusOK || out["archived"] != true {
		t.Fatalf("archive: %d %v", code, out)
	}
	out := read(T, "")
	at, _ := out["archived_at"].(string)
	if _, err := time.Parse(time.RFC3339Nano, at); err != nil || out["archived_by"] != "HUM-1" {
		t.Fatalf("archived topic read: archived_at=%v archived_by=%v", out["archived_at"], out["archived_by"])
	}
	// The control: the live topic next to it is not marked.
	if out := read(L, ""); out["archived_at"] != nil {
		t.Fatalf("the live topic is marked archived: %v", out)
	}
	// An after= poll is the hot path; it carries no stamp (the first read did).
	rows, _ := out["messages"].([]any)
	first, _ := rows[0].(map[string]any)
	cur, _ := first["cursor"].(string)
	if out := read(T, "?after="+url.QueryEscape(cur)); out["archived_at"] != nil {
		t.Fatalf("an after= poll carries the stamp: %v", out)
	}
	// Unarchive: the stamp goes with it.
	if code, _ := call(t, e, tid, http.MethodDelete, "/v1/messages/"+card+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d", code)
	}
	if out := read(T, ""); out["archived_at"] != nil {
		t.Fatalf("an unarchived topic is still marked: %v", out)
	}
}

// A lobby card's thread (task_id = the card's msg_id) is archived with the
// card; the lobby itself never is, whatever its archived rows.
func TestTopicReadArchiveStampLobby(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC()
	card := putCard(t, e, tid, lobby, "", "HUM-1", hub.WUIBox, 1, now)
	putCard(t, e, tid, lobby, "", "HUM-1", hub.WUIBox, 1, now.Add(time.Second))
	putCard(t, e, tid, card, lobby, "HUM-2", hub.WUIBox, 0, now.Add(2*time.Second))
	if code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+card+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("archive: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+card, "HUM-2", nil); code != http.StatusOK || out["archived_by"] != "HUM-1" {
		t.Fatalf("archived lobby card's thread: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+lobby, "HUM-2", nil); code != http.StatusOK || out["archived_at"] != nil {
		t.Fatalf("the lobby is marked archived: %d %v", code, out)
	}
}
