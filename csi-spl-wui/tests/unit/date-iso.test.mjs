// Every absolute date is YYYY-MM-DD, in every UI locale.
import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { isoDate, isoDateTime, isoDateTimeSec, parseIsoDate, setTimeZoneSource } from "../../src/utils/date-iso.mjs"
import { isoDateTimeOffset } from "../../src/utils/date-iso-offset.mjs"

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../../src")
const BANNED = /toLocale(?:Date|Time)?String|Intl\.DateTimeFormat/

function files(dir) {
  const out = []
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) out.push(...files(p))
    else if (/\.(vue|mjs|ts)$/.test(name)) out.push(p)
  }
  return out
}

describe("iso dates", () => {
  const stamp = new Date(2026, 8, 26, 15, 4)
  it("prints a local day and a 24-hour minute", () => {
    assert.equal(isoDate(stamp), "2026-09-26")
    assert.equal(isoDateTime(stamp), "2026-09-26 15:04")
    assert.equal(isoDate("not a date"), "")
    assert.equal(isoDateTime(""), "")
  })
  /* SPL-1666 (owner t1 62e48cef): issue History prints when each event
     happened as YYYY-MM-DD HH:MM:SS; isoDateTime keeps its minute */
  it("prints seconds, every field padded, midnight as 00:00:00", () => {
    assert.equal(isoDateTimeSec(new Date(2026, 0, 5, 7, 8, 9)), "2026-01-05 07:08:09")
    assert.equal(isoDateTimeSec(new Date(2026, 11, 31, 0, 0, 0)), "2026-12-31 00:00:00")
    assert.equal(isoDateTimeSec(new Date(2026, 8, 26, 23, 59, 59)), "2026-09-26 23:59:59")
    assert.equal(isoDateTime(new Date(2026, 0, 5, 7, 8, 9)), "2026-01-05 07:08")
    assert.equal(isoDateTimeSec("not a date"), "")
    assert.equal(isoDateTimeSec(""), "")
  })
  /* spec 162 C3 (E7): the event log's When, ISO 8601 with seconds and the
     viewer's offset at that instant: summer and winter time differ */
  it("prints seconds and the viewer's offset", () => {
    setTimeZoneSource(() => "Europe/Helsinki")
    try {
      assert.equal(isoDateTimeOffset("2026-07-28T09:14:03Z"), "2026-07-28 12:14:03+03:00")
      assert.equal(isoDateTimeOffset("2026-10-28T09:14:03Z"), "2026-10-28 11:14:03+02:00")
      setTimeZoneSource(() => "America/St_Johns")
      assert.equal(isoDateTimeOffset("2026-01-05T12:00:00Z"), "2026-01-05 08:30:00-03:30")
      setTimeZoneSource(() => "UTC")
      assert.equal(isoDateTimeOffset("2026-01-05T12:00:00.900Z"), "2026-01-05 12:00:00+00:00")
      assert.equal(isoDateTimeOffset("not a date"), "")
      assert.equal(isoDateTimeOffset(""), "")
    } finally {
      setTimeZoneSource(() => "")
    }
  })
  it("accepts only a real calendar day", () => {
    assert.equal(parseIsoDate("2026-09-26"), "2026-09-26")
    assert.equal(parseIsoDate("2026-02-31"), "")
    assert.equal(parseIsoDate("26.09.2026"), "")
    assert.equal(parseIsoDate("09/26/2026"), "")
  })
  it("no component formats a date through the locale", () => {
    const hits = []
    for (const p of files(SRC)) {
      /* CLE-77908: the one helper that prints in a picked zone needs Intl;
         097 T014: its zone-explicit twin, kept out of the first screen */
      if (p.endsWith(join("utils", "date-iso.mjs")) || p.endsWith(join("utils", "date-iso-zone.mjs"))) continue
      const text = readFileSync(p, "utf8")
      text.split("\n").forEach((line, i) => {
        if (BANNED.test(line)) hits.push(`${p}:${i + 1}`)
      })
    }
    assert.deepEqual(hits, [])
  })
})
