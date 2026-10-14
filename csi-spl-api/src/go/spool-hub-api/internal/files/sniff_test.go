package files

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// SPL-1808: the type of a nameless blob comes from its bytes.
func TestSniffExt(t *testing.T) {
	cases := []struct {
		name, data, want string
	}{
		{"png", "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR", "png"},
		{"jpg", "\xff\xd8\xff\xe0\x00\x10JFIF", "jpg"},
		{"gif", "GIF89a\x01\x00", "gif"},
		{"webp", "RIFF\x24\x00\x00\x00WEBPVP8 ", "webp"},
		{"pdf", "%PDF-1.7\n", "pdf"},
		{"zip", "PK\x03\x04\x14\x00", "zip"},
		{"mp4", "\x00\x00\x00\x18ftypisom", "mp4"},
		{"svg", "<?xml version=\"1.0\"?>\n<svg xmlns=\"http://www.w3.org/2000/svg\"/>", "svg"},
		{"json", "{\"a\": [1, 2]}\n", "json"},
		{"md", "some words\n\n## A heading\n\n- item\n", "md"},
		{"md table", "| a | b |\n|---|---|\n| 1 | 2 |\n", "md"},
		{"txt", "just a line of text\nand another\n", "txt"},
		{"binary", "\x00\x01\x02\x03\xfe\xff", ""},
		{"latin1", "caf\xe9 au lait", ""},
		{"empty", "", ""},
	}
	dir := t.TempDir()
	for _, c := range cases {
		p := filepath.Join(dir, strings.ReplaceAll(c.name, " ", "-"))
		if err := os.WriteFile(p, []byte(c.data), 0o644); err != nil {
			t.Fatal(err)
		}
		got, err := SniffExt(p)
		if err != nil || got != c.want {
			t.Errorf("%s: SniffExt = %q, %v; want %q", c.name, got, err, c.want)
		}
	}
	// A text file longer than the sniff window, cut inside a rune, is text.
	long := strings.Repeat("ä", sniffLen) // 2 bytes each: the cut lands on a rune edge or inside one
	p := filepath.Join(dir, "long")
	os.WriteFile(p, []byte("x"+long), 0o644) //nolint:errcheck
	if got, _ := SniffExt(p); got != "txt" {
		t.Errorf("long utf-8 text = %q, want txt", got)
	}
}

func TestIsHashNameAndRepairedName(t *testing.T) {
	id := strings.Repeat("ab", 32)
	if !IsHashName(id, id, id) {
		t.Fatal("own sha as name is a hash name")
	}
	for _, c := range [][3]string{
		{"shot.png", id, id},               // a real name
		{strings.Repeat("cd", 32), id, id}, // some other sha
		{strings.ToUpper(id), id, id},      // not the stored spelling
		{id[:63], id, id},                  // not 64 hex
	} {
		if IsHashName(c[0], c[1], c[2]) {
			t.Errorf("IsHashName(%q) = true", c[0])
		}
	}
	if got := RepairedName(id, "png"); got != "file-abababababab.png" {
		t.Fatalf("RepairedName = %q", got)
	}
}
