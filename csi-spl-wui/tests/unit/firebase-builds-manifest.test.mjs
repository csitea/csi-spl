// CLE-77803: an old tab, still on the previous deploy, asks the host for its
// own build's app manifest — /_nuxt/builds/meta/<old-id>.json and
// /_nuxt/builds/latest.json. After a WUI deploy that build's files are gone,
// so the request 404s at the static layer and falls through to the SPA
// rewrite (** -> /200.html), which answers 200 with the index HTML. Nuxt then
// tries to parse HTML as its manifest and logs
//   [nuxt] Received malformed app manifest. Ensure that builds/meta/*.json is
//   served as JSON by your host
// (prd human_events: HUM-10 x3, HUM-24 x2, HUM-5 x1, 2026-09-30). A 404 is the
// clean signal — Nuxt treats the build as outdated and the tab reloads into
// the live build (build-watch.client.ts / chunk-reload.client.ts).
//
// Firebase Hosting rewrites are first-match-wins and terminal, and a rewrite
// whose destination file does not exist answers 404. So a /_nuxt/builds/**
// rewrite placed BEFORE the SPA catch-all, pointing at a path nuxt generate
// never emits, turns those stale requests back into 404s. The current build's
// files still exist and are served at the static layer, before any rewrite.
//
// The DEPLOYED firebase.json is rendered from cnf by
// csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh at deploy time (it
// overwrites the checked-in csi-spl-wui/firebase.json). So the render script is
// the source of truth this test must guard; the checked-in file is kept in
// sync as the local `firebase serve` snapshot.
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const REPO = join(WUI, '..')
const BUILDS = '/_nuxt/builds/**'
const SPA = '/200.html'

function assertBuildsBeforeCatchAll(rewrites, label) {
  const idx = (src) => rewrites.findIndex((r) => r.source === src)
  const builds = idx(BUILDS)
  const catchAll = idx('**')
  assert.notEqual(builds, -1, `${label}: /_nuxt/builds/** must have its own rewrite`)
  assert.notEqual(catchAll, -1, `${label}: the ** SPA catch-all must exist`)
  assert.ok(builds < catchAll, `${label}: /_nuxt/builds/** must be matched before the ** catch-all`)
  assert.equal(catchAll, rewrites.length - 1, `${label}: the ** catch-all stays the last rewrite`)
  assert.equal(rewrites[catchAll].destination, SPA, `${label}: the catch-all still serves the SPA page`)
  const dest = rewrites[builds].destination
  assert.notEqual(dest, SPA, `${label}: a stale manifest must not be answered with the app HTML`)
  assert.ok(typeof dest === 'string' && dest.length > 0, `${label}: it rewrites to a destination (a missing file => 404)`)
  // the destination must be a path nuxt generate never writes, so it 404s
  assert.ok(!dest.startsWith('/_nuxt/builds/') || /__/.test(dest),
    `${label}: the destination must be a sentinel the build never emits`)
}

describe('firebase hosting: stale Nuxt build manifests 404, never the SPA page', () => {
  it('the checked-in csi-spl-wui/firebase.json snapshot', () => {
    const cfg = JSON.parse(readFileSync(join(WUI, 'firebase.json'), 'utf8'))
    assertBuildsBeforeCatchAll(cfg.hosting.rewrites, 'checked-in firebase.json')
  })

  it('the deploy-time render script (the source of truth)', () => {
    const script = readFileSync(join(REPO, 'csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh'), 'utf8')
    // the rewrites are a python-literal list in a heredoc; find each source
    // line in order and check the builds one precedes the catch-all.
    const buildsAt = script.indexOf(`"source": "${BUILDS}"`)
    const catchAllAt = script.indexOf('"source": "**", "destination": "/200.html"')
    assert.notEqual(buildsAt, -1, 'render script must emit a /_nuxt/builds/** rewrite')
    assert.notEqual(catchAllAt, -1, 'render script must keep the ** -> /200.html catch-all')
    assert.ok(buildsAt < catchAllAt, 'render script: /_nuxt/builds/** must come before the ** catch-all')
    // its destination is a sentinel, never the SPA page
    const line = script.slice(buildsAt, script.indexOf('\n', buildsAt))
    assert.ok(!line.includes('/200.html'), 'render script: the builds rewrite must not serve the SPA page')
    assert.match(line, /"destination":\s*"\/__[^"]*"/, 'render script: the builds rewrite points at a sentinel path')
  })
})
