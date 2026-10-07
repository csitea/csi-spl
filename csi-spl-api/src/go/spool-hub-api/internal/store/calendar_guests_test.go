package store

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// specs/097 T007: guests and answers on Memory and Postgres. AC-05 (a guest
// answers maybe, the owner sees it, a non-guest is refused, a private event
// is readable by its guests and nobody else), a PATCH of the list keeps a
// kept guest's answer, scope this / all on a series, and AC-08 for guests
// (workspace B neither reads, lists nor answers A's event; in Postgres a
// guest row of B cannot point at an event of A).

const calGuestHuman = "33333333-3333-4333-8333-333333333333" // a member invited as a guest

func calGuests() []CalendarGuest {
	return []CalendarGuest{{Type: "agent", ID: calAgent}, {Type: "human", ID: calGuestHuman}}
}

// calAnswers is e's guests as "id=response" in the stored order.
func calAnswers(e CalendarEvent) string {
	var out []string
	for _, g := range e.Guests {
		out = append(out, g.ID+"="+g.Response)
	}
	return strings.Join(out, ",")
}

func TestCalendarGuestsAC05(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal, g := st.(Calendar), st.(CalendarGuests)
			tid := newTenant(t, st)
			e := calEvent("1:1")
			e.Audience, e.Guests = CalendarPrivate, calGuests()
			e, err := cal.CreateCalendarEvent(ctx, tid, e, calT0)
			if err != nil {
				t.Fatal(err)
			}
			if calAnswers(e) != calAgent+"=needs_action,"+calGuestHuman+"=needs_action" ||
				!slices.Contains(e.Mentions, calGuestHuman) || !slices.Contains(e.Mentions, calAgent) || e.Guests[0].InvitedBy != calOwner {
				t.Fatalf("the create: guests %+v mentions %v", e.Guests, e.Mentions)
			}
			// A private event: its guests read it, a member who is not one does not.
			for _, who := range []string{calOwner, calGuestHuman, calAgent} {
				if got, err := cal.GetCalendarEvent(ctx, tid, who, e.ID); err != nil || calAnswers(got) != calAnswers(e) {
					t.Fatalf("%s reads the private event: %+v %v", who, got, err)
				}
			}
			if _, err := cal.GetCalendarEvent(ctx, tid, calMember, e.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a non-guest reads the private event: %v", err)
			}
			if _, err := g.RespondCalendarEvent(ctx, tid, calMember, e.ID, CalendarRSVP{Response: CalendarYes}, calT0); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a non-guest answers a private event they cannot see: %v", err)
			}
			// The guest answers maybe; the owner sees it; updated_at stays.
			later := calT0.Add(time.Minute)
			got, err := g.RespondCalendarEvent(ctx, tid, calGuestHuman, e.ID, CalendarRSVP{Response: CalendarMaybe, Comment: "late"}, later)
			if err != nil || calAnswers(got) != calAgent+"=needs_action,"+calGuestHuman+"=maybe" || !got.UpdatedAt.Equal(e.UpdatedAt) {
				t.Fatalf("answer maybe: %+v %v", got, err)
			}
			own, err := cal.GetCalendarEvent(ctx, tid, calOwner, e.ID)
			if err != nil || calAnswers(own) != calAnswers(got) || own.Guests[1].Comment != "late" || !own.Guests[1].RespondedAt.Equal(later) {
				t.Fatalf("the owner sees the answer: %+v %v", own.Guests, err)
			}
			// The owner is not a guest; neither is a refused answer stored.
			if _, err := g.RespondCalendarEvent(ctx, tid, calOwner, e.ID, CalendarRSVP{Response: CalendarYes}, later); !errors.Is(err, ErrNotAGuest) {
				t.Fatalf("the owner answers: %v", err)
			}
			for _, bad := range []CalendarRSVP{{Response: "needs_action"}, {Response: "sure"}, {Response: CalendarYes, Scope: CalendarScopeFollowing},
				{Response: CalendarYes, Comment: strings.Repeat("x", 501)}} {
				if _, err := g.RespondCalendarEvent(ctx, tid, calGuestHuman, e.ID, bad, later); !errors.Is(err, ErrInvalidCalendarEvent) {
					t.Fatalf("a bad answer %+v: %v", bad, err)
				}
			}
			// A public event: a member who is not a guest is refused, not hidden.
			pub, err := cal.CreateCalendarEvent(ctx, tid, CalendarEvent{Title: "all hands", Kind: "other", StartsAt: calT0,
				EndsAt: calT0.Add(time.Hour), CreatorType: "human", CreatorID: calOwner, Guests: calGuests()}, calT0)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := g.RespondCalendarEvent(ctx, tid, calMember, pub.ID, CalendarRSVP{Response: CalendarYes}, later); !errors.Is(err, ErrNotAGuest) {
				t.Fatalf("a non-guest answers a public event: %v", err)
			}
			if _, err := g.RespondCalendarEvent(ctx, tid, calAgent, pub.ID, CalendarRSVP{Response: CalendarNo}, later); err != nil {
				t.Fatalf("CONTROL: an agent guest answers: %v", err)
			}
		})
	}
}

// A PATCH writes the full new list: a kept guest keeps their answer, a
// dropped one goes, a new one has no answer yet.
func TestCalendarGuestsPatch(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal, g := st.(Calendar), st.(CalendarGuests)
			tid := newTenant(t, st)
			e := calEvent("review")
			e.Guests = calGuests()
			e, err := cal.CreateCalendarEvent(ctx, tid, e, calT0)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := g.RespondCalendarEvent(ctx, tid, calGuestHuman, e.ID, CalendarRSVP{Response: CalendarYes}, calT0); err != nil {
				t.Fatal(err)
			}
			next := []CalendarGuest{{Type: "human", ID: calGuestHuman}, {Type: "human", ID: calMember, InvitedBy: calGuestHuman}}
			got, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, e.ID, CalendarPatch{Guests: &next}, calT0.Add(time.Minute))
			if want := calMember + "=needs_action," + calGuestHuman + "=yes"; err != nil || calAnswers(got) != want {
				t.Fatalf("patch the list: %+v %v", got.Guests, err)
			}
			read, err := cal.GetCalendarEvent(ctx, tid, calOwner, e.ID)
			if err != nil || calAnswers(read) != calAnswers(got) || len(read.Guests) != 2 {
				t.Fatalf("read back the list: %+v %v", read.Guests, err)
			}
			empty := []CalendarGuest{}
			if got, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, e.ID, CalendarPatch{Guests: &empty}, calT0.Add(2*time.Minute)); err != nil || len(got.Guests) != 0 {
				t.Fatalf("clear the list: %+v %v", got.Guests, err)
			}
			if read, _ := cal.GetCalendarEvent(ctx, tid, calOwner, e.ID); len(read.Guests) != 0 {
				t.Fatalf("the cleared list reads back: %+v", read.Guests)
			}
			bad := calEvent("bad")
			bad.Guests = []CalendarGuest{{Type: "robot", ID: "x"}}
			if _, err := cal.CreateCalendarEvent(ctx, tid, bad, calT0); !errors.Is(err, ErrInvalidCalendarEvent) {
				t.Fatalf("a guest of type robot: %v", err)
			}
		})
	}
}

// On a series: scope this answers one occurrence, all every one; a series
// id takes no scope this.
func TestCalendarGuestsSeries(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal, g := st.(Calendar), st.(CalendarGuests)
			tid := newTenant(t, st)
			s := calAC04()
			s.Guests = calGuests()
			s, err := cal.CreateCalendarEvent(ctx, tid, s, calT0)
			if err != nil {
				t.Fatal(err)
			}
			mine := func() string {
				var out []string
				for _, e := range calList(t, cal, tid) {
					for _, x := range e.Guests {
						if x.ID == calGuestHuman {
							out = append(out, x.Response)
						}
					}
				}
				return strings.Join(out, ",")
			}
			occs := calList(t, cal, tid)
			got, err := g.RespondCalendarEvent(ctx, tid, calGuestHuman, occs[1].ID, CalendarRSVP{Response: CalendarYes}, calT0)
			if err != nil || got.ID != occs[1].ID || got.Guests[1].Response != CalendarYes {
				t.Fatalf("answer this: %+v %v", got, err)
			}
			if m := mine(); m != "needs_action,yes,needs_action,needs_action,needs_action,needs_action" {
				t.Fatalf("after this: %s", m)
			}
			if _, err := g.RespondCalendarEvent(ctx, tid, calGuestHuman, s.ID, CalendarRSVP{Response: CalendarNo, Scope: CalendarScopeThis}, calT0); !errors.Is(err, ErrInvalidCalendarEvent) {
				t.Fatalf("scope this on a series id: %v", err)
			}
			got, err = g.RespondCalendarEvent(ctx, tid, calGuestHuman, occs[3].ID, CalendarRSVP{Response: CalendarMaybe, Scope: CalendarScopeAll}, calT0)
			if err != nil || got.ID != occs[3].ID || got.Guests[1].Response != CalendarMaybe {
				t.Fatalf("answer all: %+v %v", got, err)
			}
			if m := mine(); m != "maybe,maybe,maybe,maybe,maybe,maybe" {
				t.Fatalf("after all: %s", m)
			}
			// edit "all" with a new list: the exception follows it, keeping its own answer.
			next := []CalendarGuest{{Type: "human", ID: calGuestHuman}}
			if _, err := cal.UpdateCalendarEvent(ctx, tid, calOwner, s.ID, CalendarPatch{Guests: &next}, calT0); err != nil {
				t.Fatal(err)
			}
			for _, e := range calList(t, cal, tid) {
				if calAnswers(e) != calGuestHuman+"=maybe" {
					t.Fatalf("an occurrence after the new list: %s %s", e.ID, calAnswers(e))
				}
			}
		})
	}
}

// AC-08 for guests: B neither reads nor answers A's event, nor its guests.
func TestCalendarGuestsCrossTenant(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cal, g := st.(Calendar), st.(CalendarGuests)
			a, b := newTenant(t, st), newTenant(t, st)
			e := calEvent("a-only")
			e.Guests = calGuests()
			e, err := cal.CreateCalendarEvent(ctx, a, e, calT0)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := cal.GetCalendarEvent(ctx, b, calGuestHuman, e.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("B reads A's event and its guests: %v", err)
			}
			if _, err := g.RespondCalendarEvent(ctx, b, calGuestHuman, e.ID, CalendarRSVP{Response: CalendarYes}, calT0); !errors.Is(err, ErrNotFound) {
				t.Fatalf("B answers A's event: %v", err)
			}
			if got, _ := cal.GetCalendarEvent(ctx, a, calOwner, e.ID); calAnswers(got) != calAgent+"=needs_action,"+calGuestHuman+"=needs_action" {
				t.Fatalf("A's answers changed: %s", calAnswers(got))
			}
			pg, ok := st.(*Postgres)
			if !ok {
				return
			}
			// The composite foreign key: a guest row of B naming A's event is
			// impossible, not only unreadable (spec 3.2).
			err = pg.inTenant(ctx, b, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `INSERT INTO calendar_guests (tenant_id, event_id, guest_type, guest_id, invited_by)
					VALUES ($1, $2::uuid, 'human', $3, $3)`, b, e.ID, calMember)
				return err
			})
			if err == nil || !strings.Contains(err.Error(), "foreign key") {
				t.Fatalf("a guest row of B on A's event: %v", err)
			}
			// CONTROL: the same row in A's own scope is accepted.
			if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `INSERT INTO calendar_guests (tenant_id, event_id, guest_type, guest_id, invited_by)
					VALUES ($1, $2::uuid, 'human', $3, $3)`, a, e.ID, calMember)
				return err
			}); err != nil {
				t.Fatalf("CONTROL: A's own guest row: %v", err)
			}
		})
	}
}
