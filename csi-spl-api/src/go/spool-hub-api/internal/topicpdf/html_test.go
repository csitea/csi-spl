// SPDX-License-Identifier: AGPL-3.0-only

package topicpdf

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/png"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// testPNG is a small synthetic picture and its sha256 (the blob's file_id).
func testPNG(t *testing.T) ([]byte, string) {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 8, 8))
	for i := range 8 {
		img.Set(i, i, color.RGBA{R: 200, A: 255})
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b.Bytes())
	return b.Bytes(), hex.EncodeToString(sum[:])
}

func row(t *testing.T, id, body string, at time.Time, files ...msg.Attachment) store.EditableMessage {
	t.Helper()
	inner, err := json.Marshal(map[string]any{"v": 1, "msg_id": id, "body": body, "files": files})
	if err != nil {
		t.Fatal(err)
	}
	return store.EditableMessage{MsgID: id, FromID: "c-004", Kind: "note", Body: body, Msg: inner, TS: at}
}

// fixture is spec 183 row P2's: 3 rows, the second with 1 picture.
func fixture(t *testing.T) ([]store.EditableMessage, func(string) ([]byte, error), []byte) {
	t.Helper()
	pic, id := testPNG(t)
	at := time.Date(2026, 11, 20, 8, 0, 0, 0, time.UTC)
	rows := []store.EditableMessage{
		row(t, "m1", "The export starter row", at),
		row(t, "m2", "Second row with a **picture**", at.Add(time.Minute),
			msg.Attachment{Mode: "blob", Kind: "file", FileID: id, SHA256: id, Name: "chart.png", Bytes: int64(len(pic))}),
		row(t, "m3", "Third row closes it", at.Add(2*time.Minute)),
	}
	blob := func(fileID string) ([]byte, error) {
		if fileID == id {
			return pic, nil
		}
		return nil, errors.New("no such blob")
	}
	return rows, blob, pic
}

func TestHTMLInlinesThePicture(t *testing.T) {
	rows, blob, pic := fixture(t)
	page, n, err := HTML(rows, Title(rows), blob)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("pictures = %d, want 1", n)
	}
	want := "data:image/png;base64," + base64.StdEncoding.EncodeToString(pic)
	if !bytes.Contains(page, []byte(`src="`+want+`"`)) {
		t.Fatalf("the picture's data: URL is not in the HTML")
	}
	for _, s := range []string{"<title>The export starter row</title>", "The export starter row",
		"Second row with a <strong>picture</strong>", "Third row closes it", "<figcaption>chart.png</figcaption>"} {
		if !bytes.Contains(page, []byte(s)) {
			t.Errorf("HTML misses %q", s)
		}
	}
	if bytes.Contains(page, []byte("http://")) || bytes.Contains(page, []byte("https://")) {
		t.Errorf("the HTML names a remote resource")
	}
}

func TestHTMLPicturePrintsAsNameWhenItCannotInline(t *testing.T) {
	rows, blob, _ := fixture(t)
	bad := func(string) ([]byte, error) { return []byte("\x89PNG not the hashed bytes"), nil }
	for name, b := range map[string]func(string) ([]byte, error){"nil blob": nil, "hash mismatch": bad,
		"read error": func(string) ([]byte, error) { return nil, errors.New("gone") }} {
		page, n, err := HTML(rows, "t", b)
		if err != nil || n != 0 || bytes.Contains(page, []byte("data:")) ||
			!bytes.Contains(page, []byte(`<p class="msg-print__file">chart.png</p>`)) {
			t.Errorf("%s: n=%d err=%v; want the name only", name, n, err)
		}
	}
	_ = blob
}

func TestHTMLFileLinkAndBudget(t *testing.T) {
	rows, blob, _ := fixture(t)
	page, _, _ := HTML(rows, "t", blob, WithTopicLink("https://wui.example.com/t/abc"))
	if bytes.Contains(page, []byte(`<p class="msg-print__file">`)) {
		t.Fatalf("the picture inlined, so no file line is expected")
	}
	doc := row(t, "m4", "a doc", rows[0].TS, msg.Attachment{Mode: "blob", Kind: "file", FileID: "ab", Name: "notes.txt"})
	page, _, _ = HTML([]store.EditableMessage{doc}, "t", blob, WithTopicLink("https://wui.example.com/t/abc"))
	if !bytes.Contains(page, []byte(`<p class="msg-print__file">notes.txt <a href="https://wui.example.com/t/abc">https://wui.example.com/t/abc</a></p>`)) {
		t.Fatalf("a file is not a link to the topic:\n%s", page)
	}
	page, _, _ = HTML([]store.EditableMessage{doc}, "t", blob, WithTopicLink("javascript:alert(1)"))
	if bytes.Contains(page, []byte("javascript")) {
		t.Fatalf("a non-http link was kept")
	}
	if src := pictureSrc(attachments(rows[1].Msg)[0], blob, 10); src != "" {
		t.Fatalf("a picture over the budget inlined")
	}
}

func TestImageMime(t *testing.T) {
	cases := map[string]string{
		"\x89PNG\r\n": "image/png", "\xff\xd8\xff\xe0": "image/jpeg", "GIF89a": "image/gif",
		"RIFF\x00\x00\x00\x00WEBPVP8": "image/webp", "\x00\x00\x00\x1cftypavif": "image/avif",
		"BM" + strings.Repeat("\x00", 20): "image/bmp", "\x00\x00\x01\x00": "image/x-icon",
		"\ufeff  <svg xmlns='x'>": "image/svg+xml", "<?xml version='1.0'?><svg>": "image/svg+xml",
		"<html>": "", "plain": "",
	}
	for in, want := range cases {
		if got := imageMime([]byte(in)); got != want {
			t.Errorf("imageMime(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestMarkdownEscapesAndMarks(t *testing.T) {
	src := "# Head\n<script>alert(1)</script> and `a<b` and [x](https://example.com/a?b=1&c=2) [y](javascript:z)\n" +
		"- one\n- *two*\n\n1. first\n\n> quoted\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```\n<raw> **not bold**\n```\nlast\nline"
	got := string(Markdown(src))
	for _, s := range []string{"<h1>Head</h1>", "&lt;script&gt;alert(1)&lt;/script&gt;", "<code>a&lt;b</code>",
		`<a href="https://example.com/a?b=1&amp;c=2">x</a>`, "[y](javascript:z)", "<ul><li>one</li><li><em>two</em></li></ul>",
		"<ol><li>first</li></ol>", "<blockquote>quoted</blockquote>", "<tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr>",
		"<pre><code>&lt;raw&gt; **not bold**</code></pre>", "<p>last<br>line</p>"} {
		if !strings.Contains(got, s) {
			t.Errorf("Markdown misses %q in:\n%s", s, got)
		}
	}
	if strings.Contains(got, "<script>") {
		t.Fatalf("a tag of the body reached the HTML")
	}
}

// An empty title (no text in the topic) prints its heading as "topic".
func TestHTMLEmptyTitleHeadsTopic(t *testing.T) {
	page, _, err := HTML(nil, "", nil)
	if err != nil || !bytes.Contains(page, []byte(`<h1 class="msg-print__title">topic</h1>`)) {
		t.Fatalf("err=%v page:\n%s", err, page)
	}
}
