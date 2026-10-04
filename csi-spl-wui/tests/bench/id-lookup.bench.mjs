// HUM-10 (topic cd357c76): what the hub id lookup adds to rendering a long
// DM. The owner's limit is a slowdown of at most 1%. One round renders every
// body of the conversation (parseBody, which links ids); the bodies quote
// ids the tab holds and ids it does not. The lookup is the plugin's wiring
// (id-catalog-install.ts) without the stores, after its one answer: what
// every repaint pays. A tree without id-lookup.mjs is the BEFORE.
import { bench, src } from './lib/bench.mjs'

const { parseBody } = await src('utils/code-blocks.mjs')
const { indexCatalog, resolveId, setIdCatalogProvider } = await src('utils/id-links.mjs')
const gate = await src('utils/id-link-gate.mjs')
const lookupMod = await src('utils/id-lookup.mjs').catch(() => null)

const uuid = (p, i) => `${p}${String(i).padStart(7, '0')}-0000-4000-8000-${String(i).padStart(12, '0')}`
const loaded = Array.from({ length: 300 }, (_, i) => ({ msg_id: uuid('a', i), task_id: uuid('b', i), channel: null, from: 'HUM-1', to: 'c-001', to_box: 'box-a' }))
const HUB_EMPTY = process.env.HUB_EMPTY === '1'
const hub = (ids) => ({ ids: HUB_EMPTY ? [] : ids.filter((id) => id.startsWith('c')).map((id) => ({ id, kind: 'topic', task_id: id, channel: 'dev-ops' })) })

function bodies(n) {
  return Array.from({ length: n }, (_, i) =>
    `Status ${i}: landed the change for ${uuid('b', i % 300)}, see ${uuid('c', i)} in the other channel ` +
    `and reply ${uuid('d', i)}. The run was green; **next** I check the deploy and report back. ` +
    'A line without any id, long enough to be a normal message in a direct conversation with an agent.')
}

for (const n of [300, 1000]) {
  const list = bodies(n)
  let lk = null
  if (lookupMod && gate.registerIdLookup) {
    lk = lookupMod.createIdLookup({ fetchIds: async (ids) => hub(ids), resolves: (t, i) => Boolean(resolveId(t, i)), onHits: () => {}, schedule: (fn) => fn() })
    gate.registerIdLookup((src, index) => lk.note(src, index))
  }
  let cache = null
  setIdCatalogProvider(() => {
    const v = lk ? lk.version : 0
    if (cache && cache.v === v) return cache.index
    const asked = lk ? lk.rows('HUM-1') : { topics: [], messages: [] }
    cache = { v, index: indexCatalog({ topics: asked.topics, messages: [...loaded, ...asked.messages], self: 'HUM-1' }) }
    return cache.index
  })
  for (const b of list) parseBody(b)
  await new Promise((r) => setTimeout(r, 0))
  bench(`id-lookup render bodies=${n} lookup=${lk ? (HUB_EMPTY ? 'on, hub answers none' : 'on') : 'absent'}`, () => {
    let links = 0
    for (const b of list) for (const blk of parseBody(b)) for (const p of blk.parts || []) if (p.type === 'link') links++
    return links
  })
  if (gate.registerIdLookup) gate.registerIdLookup(null)
}
