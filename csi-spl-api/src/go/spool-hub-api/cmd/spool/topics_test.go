package main

import (
	"bytes"
	"testing"
)

// printTopics: one "<task_id>  <last activity>  <subject>" line per topic,
// then the next cursor; no body ever reaches the page, so none is printed.
func TestPrintTopics(t *testing.T) {
	var b bytes.Buffer
	raw := `{"channel":"refactoring","topics":[` +
		`{"task_id":"0b9e4c1a-1111-4aaa-8bbb-000000000001","subject":"split the store","last_ts":"2026-10-12T06:01:02.5Z"},` +
		`{"task_id":"0b9e4c1a-1111-4aaa-8bbb-000000000002","subject":"","last_ts":"not a time"}],"next":"CUR"}`
	if err := printTopics(&b, []byte(raw)); err != nil {
		t.Fatal(err)
	}
	want := "0b9e4c1a-1111-4aaa-8bbb-000000000001  2026-10-12 06:01Z  split the store\n" +
		"0b9e4c1a-1111-4aaa-8bbb-000000000002  not a time  \n" +
		"next: CUR\n"
	if b.String() != want {
		t.Fatalf("got\n%q\nwant\n%q", b.String(), want)
	}
	b.Reset()
	if err := printTopics(&b, []byte(`{"channel":"x","topics":[],"next":null}`)); err != nil || b.Len() != 0 {
		t.Fatalf("empty page printed %q (%v)", b.String(), err)
	}
	if err := printTopics(&b, []byte(`not json`)); err == nil {
		t.Fatal("bad reply: want an error")
	}
}
