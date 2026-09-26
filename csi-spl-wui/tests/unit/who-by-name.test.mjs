// SPL-6: humans by their display name everywhere. The lobby status line and
// the new-message announcement used to print the member id (HUM-n) even when
// the member had chosen a name; both now go through the display-name label.
import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { personLabel } from "../../src/utils/channel-feed.mjs"

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../../src")
const read = (p) => readFileSync(join(SRC, p), "utf8")

describe("who reads as a display name", () => {
  it("the lobby status names the viewer through people.label", () => {
    const s = read("pages/lobby.vue")
    assert.match(s, /'pages\.lobby\.status'[^\n]*who: live\.identity\.value \? people\.label\(live\.identity\.value\)/)
    assert.doesNotMatch(s, /who: live\.identity\.value \|\|/)
  })
  it("the new-message announcement names the sender through people.label", () => {
    const s = read("components/LiveFeed.vue")
    assert.match(s, /'feed\.announce_new', \{ who: people\.label\(/)
  })
  it("the label is the name for a named human, id@box for an agent (CONTROL)", () => {
    const names = { "HUM-4": "Named Person" }
    assert.equal(personLabel("HUM-4", undefined, names), "Named Person")
    assert.equal(personLabel("HUM-4", "box-wui", names), "Named Person")
    assert.equal(personLabel("HUM-9", undefined, names), "HUM-9")
    assert.equal(personLabel("CLE-07", "box-a", names), "CLE-07@box-a")
  })
})
