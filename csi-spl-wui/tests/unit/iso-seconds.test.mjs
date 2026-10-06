// isoSeconds stamps RFC 3339 UTC at seconds precision.
// The source guard scans src/ (vue, mjs, ts), the same tree as
// date-iso.test.mjs. Four copies still owned by earlier rows stay
// allow-listed: spool-client-lazy.mjs (two), channel-feed.mjs,
// issues-view.mjs. nuxt.config.ts stamps buildAt the same way and
// lives outside src/; this row does not own that file.
import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { readdirSync, readFileSync, statSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { isoSeconds } from "../../src/utils/iso-seconds.mjs"

const SRC = join(dirname(fileURLToPath(import.meta.url)), "../../src")
const ALLOW = [
  join("utils", "iso-seconds.mjs"),
  join("utils", "spool-client-lazy.mjs"),
  join("utils", "channel-feed.mjs"),
  join("utils", "issues-view.mjs"),
]

function files(dir) {
  const out = []
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) out.push(...files(p))
    else if (/\.(vue|mjs|ts)$/.test(name)) out.push(p)
  }
  return out
}

describe("isoSeconds", () => {
  it("drops the fraction toISOString emits", () => {
    assert.equal(isoSeconds(new Date(Date.UTC(2026, 0, 2, 3, 4, 5, 678))), "2026-01-02T03:04:05Z")
  })
  it("no toISOString().replace( outside the helper, except rows still owned elsewhere", () => {
    const hits = []
    for (const p of files(SRC)) {
      if (ALLOW.some((rel) => p.endsWith(rel))) continue
      const text = readFileSync(p, "utf8")
      text.split("\n").forEach((line, i) => {
        if (line.includes("toISOString().replace(")) hits.push(`${p}:${i + 1}`)
      })
    }
    assert.deepEqual(hits, [])
  })
})
