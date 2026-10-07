package github

import "testing"

func TestNoreplyDomain(t *testing.T) {
	for api, want := range map[string]string{
		"https://api.example.com":        "users.noreply.example.com",
		"https://api.example.com/":       "users.noreply.example.com",
		"https://ghe.example.net/api/v3": "users.noreply.ghe.example.net",
		"http://127.0.0.1:8080":          "users.noreply.127.0.0.1",
	} {
		if got := noreplyDomain(api); got != want {
			t.Errorf("noreplyDomain(%q) = %q, want %q", api, got, want)
		}
	}
}
