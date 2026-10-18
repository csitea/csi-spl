// SPL-2168: WUI production-relevant environment variables documented in README.md
// Test that every NUXT_* variable read or defined by csi-spl-wui is documented in the README table.
import { readFileSync } from "node:fs"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"
import { spawnSync } from "node:child_process"

const __dirname = dirname(fileURLToPath(import.meta.url))
const WUI = join(__dirname, "../..")

let failed = 0
const pass = (n) => console.log("  OK  ", n)
const fail = (n, m) => { failed++; console.log("  FAIL", n + ":", m) }
const eq = (got, want, n) => {
  const g = JSON.stringify(got)
  const w = JSON.stringify(want)
  return g === w ? pass(n) : fail(n, `got ${g}, want ${w}`)
}

/**
 * Extract all NUXT_* environment variable tokens from the WUI codebase (excluding tests/ and node_modules).
 */
export function extractCodeNuxtVars(wuiDir = WUI) {
  const res = spawnSync("git", ["grep", "-ohE", "NUXT_[A-Z0-9_]+", "--", "nuxt.config.ts", "src/"], {
    cwd: wuiDir,
    encoding: "utf8",
  })
  if (res.error) throw res.error
  if (res.status !== 0 && res.status !== 1) {
    throw new Error(`git grep failed with status ${res.status}: ${res.stderr}`)
  }
  const lines = res.stdout ? res.stdout.split("\n").filter(Boolean) : []
  // Filter out any partial tokens like NUXT_ or NUXT_PUBLIC_ if present
  return new Set(lines.filter((v) => /^NUXT_[A-Z0-9]+(_[A-Z0-9]+)*$/.test(v)))
}

/**
 * Extract all documented NUXT_* variables from the markdown content (table rows).
 */
export function extractDocNuxtVars(markdown) {
  const tableRows = markdown.matchAll(/\|\s*`(NUXT_[A-Z0-9_]+)`\s*\|\s*([^|]+)\|\s*([^|]+)\|\s*([^|]+)\|\s*([^|]+)\|/g)
  const vars = new Map()
  for (const m of tableRows) {
    vars.set(m[1], {
      name: m[1],
      purpose: m[2].trim(),
      whereSet: m[3].trim(),
      defaultVal: m[4].trim(),
      devOnly: m[5].trim().toLowerCase(),
    })
  }
  return vars
}

/**
 * Check that all required code variables are documented.
 * Returns array of missing variable names.
 */
export function findMissingDocVars(codeVars, docVarsMap) {
  const missing = []
  for (const v of codeVars) {
    if (!docVarsMap.has(v)) {
      missing.push(v)
    }
  }
  return missing.sort()
}

// ── Tests ──────────────────────────────────────────────────────────────────

const readmePath = join(WUI, "README.md")
const readmeContent = readFileSync(readmePath, "utf8")
const codeVars = extractCodeNuxtVars()
const docMap = extractDocNuxtVars(readmeContent)

// 1. Code variables discovered
if (codeVars.size >= 20) {
  pass(`discovered ${codeVars.size} NUXT_* variables in WUI codebase`)
} else {
  fail("code variables discovery", `found only ${codeVars.size} variables`)
}

// 2. Control: check that findMissingDocVars flags an undocumented variable
{
  const fakeVars = new Set([...codeVars, "NUXT_UNDOCUMENTED_TEST_VAR"])
  const missing = findMissingDocVars(fakeVars, docMap)
  eq(missing.includes("NUXT_UNDOCUMENTED_TEST_VAR"), true, "CONTROL: an undocumented NUXT_* variable is caught")
}

// 3. Control: empty doc map fails on all code vars
{
  const emptyMap = new Map()
  const allMissing = findMissingDocVars(codeVars, emptyMap)
  eq(allMissing.length, codeVars.size, "CONTROL: empty documentation map reports all code variables missing")
}

// 4. Verify NUXT_DEV_AUTH_PROXY is specifically documented as dev-only
{
  const devProxy = docMap.get("NUXT_DEV_AUTH_PROXY")
  if (devProxy) {
    eq(devProxy.devOnly, "yes", "NUXT_DEV_AUTH_PROXY is documented with Dev-only: yes")
  } else {
    fail("NUXT_DEV_AUTH_PROXY", "missing from documentation map")
  }
}

// 5. Verify core production-relevant variables are documented and marked not dev-only
const prodVars = [
  "NUXT_PUBLIC_API_BASE",
  "NUXT_PUBLIC_AUTH_BASE",
  "NUXT_PUBLIC_APP_VERSION",
  "NUXT_PUBLIC_USE_MOCK",
  "NUXT_PUBLIC_SITE_URL",
  "NUXT_PUBLIC_DEFAULT_LOCALE",
  "NUXT_PUBLIC_SEO_INDEX",
]
for (const pv of prodVars) {
  const entry = docMap.get(pv)
  if (entry) {
    eq(entry.devOnly, "no", `${pv} is documented with Dev-only: no`)
  } else {
    fail(pv, "missing from documentation map")
  }
}

// 6. Verify every code variable is documented in README.md
const missing = findMissingDocVars(codeVars, docMap)
if (missing.length === 0) {
  pass(`all ${codeVars.size} code NUXT_* variables are documented in README table`)
} else {
  fail("missing variables in README table", missing.join(", "))
}

if (failed > 0) {
  process.exit(1)
}
console.log("\nproduction-env-vars: all tests passed")
