package rbac

import (
	"context"
	"reflect"
	"testing"
)

// lrRolesFunc is the Roles method both fixed sources share in shape.
type lrRolesFunc func(context.Context, string) (map[string]Role, error)

// lrCheckRoles asserts a fixed source answers exactly the default roles.
func lrCheckRoles(t *testing.T, roles lrRolesFunc) {
	t.Helper()
	got, err := roles(context.Background(), "t1")
	if err != nil {
		t.Fatalf("Roles: %v", err)
	}
	if want := DefaultRoles(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Roles = %v, want DefaultRoles() %v", got, want)
	}
}

// List reads back only what is granted, sorted whatever the map order.
func TestAccessListGrantedSorted(t *testing.T) {
	a := Access{Perms: map[string]bool{
		"tasks.write": true,
		"agents.join": false,
		"admin.read":  true,
		"hours.rates": false,
		"docs.read":   true,
	}}
	want := []string{"admin.read", "docs.read", "tasks.write"}
	if got := a.List(); !reflect.DeepEqual(got, want) {
		t.Fatalf("List = %v, want %v", got, want)
	}
}

// An Access with no permissions lists nothing, nil map or empty map, and the
// answer is an empty slice rather than nil, so it marshals as [] on the wire.
func TestAccessListEmpty(t *testing.T) {
	for name, a := range map[string]Access{
		"zero value": {},
		"empty map":  {Perms: map[string]bool{}},
		"only false": {Perms: map[string]bool{"tasks.write": false}},
	} {
		got := a.List()
		if got == nil || len(got) != 0 {
			t.Errorf("%s: List = %#v, want empty non-nil", name, got)
		}
	}
}

func TestFixedRolesAreDefaults(t *testing.T) {
	lrCheckRoles(t, Fixed("biz_owner").Roles)
}

func TestFixedSetRolesAreDefaults(t *testing.T) {
	lrCheckRoles(t, FixedSet{"biz_owner", "admin"}.Roles)
}
