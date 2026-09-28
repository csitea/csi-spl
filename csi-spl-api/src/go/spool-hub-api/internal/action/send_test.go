package action

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

// Pins of SendCtx taken before it was split into check / attachments / hub
// steps (SPL-1029 round 2): every argument refusal, word for word, and the
// attachment order of a local send.

func TestSendArgRefusals(t *testing.T) {
	const hub = "http://127.0.0.1:1" // never dialled: every case is refused first
	cases := []struct {
		hub  string
		in   SendArgs
		want string
	}{
		{"", SendArgs{From: "CLE-1", To: "CLE-2", ToBox: "box-b"}, "--to-box / to_box needs hub mode ($SPOOL_HUB_URL)"},
		{"", SendArgs{From: "CLE-1", Channel: "ops"}, "--channel needs hub mode ($SPOOL_HUB_URL)"},
		{hub, SendArgs{From: "CLE-1", Channel: "-bad"}, `--channel must match ^[a-z0-9][a-z0-9-]{0,63}$, got "-bad"`},
		{hub, SendArgs{From: "CLE-1", Channel: "#Ops", ToBox: "box-b"}, "--channel posts to every member of the channel: drop --to-box"},
		{hub, SendArgs{From: "CLE-1", Channel: "ops", To: "CLE-2"}, `--channel posts to every member of the channel: --to must be empty or ALL-0, got "CLE-2"`},
		{"", SendArgs{From: "CLE-1", To: "CLE-2", TypedBy: "HUM-1"}, "--typed-by needs hub mode ($SPOOL_HUB_URL)"},
		{hub, SendArgs{From: "CLE-1", To: "CLE-2", TypedBy: "CLE-9"}, `--typed-by must be a HUM-<n> id, got "CLE-9"`},
		{"", SendArgs{From: "CLE-1", To: "CLE-2", PutFile: "/nonexistent/x"}, "stat /nonexistent/x: no such file or directory"},
	}
	for _, c := range cases {
		cfg := testkit.NewConfig(t)
		cfg.HubURL = c.hub
		if _, err := Send(cfg, c.in); err == nil || err.Error() != c.want {
			t.Errorf("%+v: got %v, want %q", c.in, err, c.want)
		}
	}
}

func TestSendLocalAttachmentOrder(t *testing.T) {
	cfg := testkit.NewConfig(t)
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	blob, err := Put(cfg, write("blob.txt", "blob"), false)
	if err != nil {
		t.Fatal(err)
	}
	sub := filepath.Join(dir, "sub")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatal(err)
	}
	write("sub/a.txt", "a")
	res, err := Send(cfg, SendArgs{From: "CLE-1", To: "CLE-2", Kind: "note", Body: "hi",
		FileIDs: []string{blob.FileID}, PutFile: write("put.txt", "put"), DirBlobs: []string{sub},
		FileRefs: []string{write("ref.txt", "ref")}, DirRefs: []string{sub}})
	if err != nil {
		t.Fatal(err)
	}
	if res.Delivery != "local" || res.MsgID == "" || res.TaskID == "" {
		t.Fatalf("result %+v", res)
	}
	msgs, err := Recv(cfg, "CLE-2", false)
	if err != nil || len(msgs) != 1 {
		t.Fatalf("recv: %v %d", err, len(msgs))
	}
	var got []string
	for _, a := range msgs[0].Files {
		got = append(got, a.Mode+"/"+a.Kind+"/"+a.Name)
	}
	want := []string{"blob/file/" + blob.FileID, // a referenced blob is named by its id
		"blob/file/put.txt", "blob/dir/sub", "path/file/ref.txt", "path/dir/sub"}
	if len(got) != len(want) {
		t.Fatalf("attachments %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("attachments %v, want %v", got, want)
		}
	}
}
