package blob

import (
	"context"
	"errors"
	"io"
	"testing"
)

func TestKey(t *testing.T) {
	id := "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	k, err := Key("t1", id)
	if err != nil || k != "t/t1/files/"+id {
		t.Fatalf("Key = %q, %v", k, err)
	}
	if _, err := Key("t1", "../../etc/passwd"); err == nil {
		t.Fatal("path traversal accepted as file_id")
	}
}

func TestDir(t *testing.T) {
	ctx := context.Background()
	d := Dir{Root: t.TempDir()}
	if ok, _ := d.Exists(ctx, "t/a/files/x"); ok {
		t.Fatal("exists before put")
	}
	if _, err := d.Get(ctx, "t/a/files/x"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("get missing: %v", err)
	}
	if err := d.Put(ctx, "t/a/files/x", []byte("hello")); err != nil {
		t.Fatal(err)
	}
	r, err := d.Get(ctx, "t/a/files/x")
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(r)
	r.Close()
	if string(b) != "hello" {
		t.Fatalf("got %q", b)
	}
	if ok, _ := d.Exists(ctx, "t/b/files/x"); ok {
		t.Fatal("object visible under another tenant prefix")
	}
}
