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
import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const WUI = join(dirname(fileURLToPath(import.meta.url)), '../..')
const cfg = JSON.parse(readFileSync(join(WUI, 'firebase.json'), 'utf8'))
const rewrites = cfg.hosting.rewrites
const idx = (src) => rewrites.findIndex((r) => r.source === src)

describe('firebase hosting: stale Nuxt build manifests 404, never the SPA page', () => {
  it('has a /_nuxt/builds/** rewrite', () => {
    assert.notEqual(idx('/_nuxt/builds/**'), -1, '/_nuxt/builds/** must have its own rewrite')
  })

  it('that rewrite does NOT serve the SPA index (that is the bug)', () => {
    const r = rewrites[idx('/_nuxt/builds/**')]
    assert.notEqual(r.destination, '/200.html', 'a stale manifest must not be answered with the app HTML')
    assert.ok(typeof r.destination === 'string' && r.destination.length > 0, 'it rewrites to a destination (a missing file => 404)')
    // the destination must be a path nuxt generate never writes, so it 404s
    assert.ok(!r.destination.startsWith('/_nuxt/builds/') || /__/.test(r.destination),
      'the destination must be a sentinel that the build never emits')
  })

  it('comes BEFORE the SPA catch-all, which stays last (first match wins)', () => {
    const builds = idx('/_nuxt/builds/**')
    const catchAll = idx('**')
    assert.notEqual(catchAll, -1, 'the ** SPA catch-all must exist')
    assert.ok(builds < catchAll, '/_nuxt/builds/** must be matched before the ** catch-all')
    assert.equal(catchAll, rewrites.length - 1, 'the ** catch-all stays the last rewrite')
    assert.equal(rewrites[catchAll].destination, '/200.html', 'the catch-all still serves the SPA page')
  })
})
