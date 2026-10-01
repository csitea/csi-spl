// Every absolute date is YYYY-MM-DD, in every UI locale.
import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { isoDate, isoDateTime, parseIsoDate } from "../../src/utils/date-iso.mjs"

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
  it("accepts only a real calendar day", () => {
    assert.equal(parseIsoDate("2026-09-26"), "2026-09-26")
    assert.equal(parseIsoDate("2026-02-31"), "")
    assert.equal(parseIsoDate("26.09.2026"), "")
    assert.equal(parseIsoDate("09/26/2026"), "")
  })
  it("no component formats a date through the locale", () => {
    const hits = []
    for (const p of files(SRC)) {
      /* CLE-77908: the one helper that prints in a picked zone needs Intl */
      if (p.endsWith(join("utils", "date-iso.mjs"))) continue
      const text = readFileSync(p, "utf8")
      text.split("\n").forEach((line, i) => {
        if (BANNED.test(line)) hits.push(`${p}:${i + 1}`)
      })
    }
    assert.deepEqual(hits, [])
  })
})
