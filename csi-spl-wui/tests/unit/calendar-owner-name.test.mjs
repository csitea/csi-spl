// SPL-5889 (owner, csitea t1 12ccd587: "the label for the human should be
// written in his first name, last name and not id"): the calendar event
// pop-over (and its phone peek) showed the owner as HUM-10. Both now render
// the owner and an issue deadline's assignee through HumanName, whose label
// is shownPerson: the member's display name (the hub's join of first + last
// name), the id only when none is known and in the title; an agent keeps its
// id. The e2e on the screen: tests/e2e/calendar-owner-name.test.mjs.
//
// Control: shownPerson returning the id, or a component printing owner_id /
// assignee as text again, turns these red.
import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { personTitle, shownPerson } from "../../src/utils/channel-feed.mjs"

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../../src")
const read = (p) => readFileSync(join(SRC, p), "utf8")
const NAMES = { "HUM-10": "FirstName LastName" }

describe("SPL-5889: a human on the calendar pop-over reads First Last", () => {
  it("a named member is their first and last name, the id in the title", () => {
    assert.equal(shownPerson("HUM-10", undefined, NAMES), "FirstName LastName")
    assert.equal(personTitle("HUM-10", undefined, NAMES), "FirstName LastName · HUM-10")
  })
  it("a member with no known name is the id", () => {
    assert.equal(shownPerson("HUM-9", undefined, NAMES), "HUM-9")
    assert.equal(shownPerson("HUM-10", undefined, {}), "HUM-10")
  })
  it("an agent keeps its id (CONTROL)", () => {
    assert.equal(shownPerson("CLE-07", undefined, NAMES), "CLE-07")
    assert.equal(shownPerson("c-829", undefined, { "c-829": "FirstName LastName" }), "c-829")
  })
  for (const [file, owner, assignee] of [
    ["components/CalendarEventPopover.vue", "calendar-popover-owner", "calendar-popover-assignee"],
    ["components/CalendarPhonePeek.vue", "calpeek-owner", "calpeek-assignee"],
  ]) {
    it(`${file}: owner and assignee go through HumanName, never the raw id`, () => {
      const s = read(file)
      const block = (test) => {
        const at = s.indexOf(`data-test="${test}"`)
        assert.ok(at > 0, test)
        return s.slice(at, s.indexOf(test.endsWith("assignee") ? "</dd>" : "</p>", at))
      }
      assert.match(block(owner), /<HumanName v-if="ownerId" :id="ownerId"/)
      assert.match(block(assignee), /<HumanName v-if="event\.assignee" :id="event\.assignee"/)
      assert.doesNotMatch(s, /\{\{\s*(ownerLabel|event\.assignee)\b/)
    })
  }
})
