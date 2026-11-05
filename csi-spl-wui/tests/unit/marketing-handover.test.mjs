// Spec 090 T036 (SPL-4804): the draft hand-over's helpers
// (src/utils/marketing-handover.mjs). The red controls of tasks.md T036:
// an unchecked photo never enters the download pack, and the clipboard text
// is the full caption with its hashtags. The ZIP is read back with Node's
// own inflate-free parser below (stored entries) and checked byte for byte.
//
// Run: node tests/unit/marketing-handover.test.mjs
import zlib from 'node:zlib'
import {
  HANDOVER_MAX_HASHTAGS, HANDOVER_MAX_PHOTOS, crc32, handoverCopyText, handoverDownloadPlan,
  handoverFileName, handoverHashtags, handoverPicked, handoverSameOrigin, handoverZip,
} from '../../src/utils/marketing-handover.mjs'
import { runsInUnitSuite } from './lib/in-suite.mjs'

let failed = 0
const ok = (name, cond, why = '') => {
  if (cond) console.log(`  OK   ${name}`)
  else { failed++; console.log(`  FAIL ${name} ${why}`) }
}

// --- the pack holds the checked photos only (RED CONTROL) ---------------------
const imgs = ['https://b.example.com/blog/img/a.jpg', 'https://b.example.com/blog/img/b.jpg', 'https://b.example.com/blog/img/c.jpg']
const picked = handoverPicked(imgs, { [imgs[0]]: true, [imgs[1]]: false, [imgs[2]]: true })
ok('an unchecked photo is excluded from the pack', picked.join() === [imgs[0], imgs[2]].join(), JSON.stringify(picked))
ok('nothing checked is an empty pack', handoverPicked(imgs, {}).length === 0)
const many = Array.from({ length: 14 }, (_, i) => `https://b.example.com/blog/img/p${i}.jpg`)
ok(`at most ${HANDOVER_MAX_PHOTOS} photos`, handoverPicked(many, Object.fromEntries(many.map((u) => [u, true]))).length === HANDOVER_MAX_PHOTOS)
ok('a truthy non-true value is not a check', handoverPicked(imgs, { [imgs[0]]: 'yes' }).length === 0)

const plan0 = handoverDownloadPlan([])
const plan1 = handoverDownloadPlan([imgs[0]])
const plan2 = handoverDownloadPlan(picked)
ok('0 / 1 / 2 photos: none, a direct download, a ZIP', plan0.kind === 'none' && plan1.kind === 'single' && plan2.kind === 'zip' &&
  plan2.urls.join() === picked.join(), JSON.stringify([plan0, plan1, plan2]))

// --- the clipboard text (RED CONTROL: the full formatted string) -------------
const caption = 'Лагер 2027\n\nThe summer camp opens.\n\nhttps://b.example.com/blog/2026-10-30-camp'
const copy = handoverCopyText(caption, '#camp, kids  #Camp languages\n#ai-tools')
ok('caption, a blank line, then each hashtag once with #', copy ===
  'Лагер 2027\n\nThe summer camp opens.\n\nhttps://b.example.com/blog/2026-10-30-camp\n\n#camp #kids #languages #aitools', JSON.stringify(copy))
ok('no hashtags: the caption alone', handoverCopyText(`  ${caption}  `, '  ') === caption)
ok('Cyrillic hashtags stay', handoverHashtags('#лагер деца').join(' ') === '#лагер #деца')
ok(`at most ${HANDOVER_MAX_HASHTAGS} hashtags`, handoverHashtags(Array.from({ length: 40 }, (_, i) => `t${i}`).join(' ')).length === HANDOVER_MAX_HASHTAGS)

// --- file names ----------------------------------------------------------------
const used = new Set()
const names = ['https://x.example.com/img/a.jpg', 'https://y.example.com/a.jpg', 'https://x.example.com/', 'https://x.example.com/p%20q.jpg']
  .map((u, i) => handoverFileName(u, i, used))
ok('file names are unique and safe', names.join() === 'a.jpg,a-2.jpg,photo-3.jpg,p_q.jpg', names.join())

// --- the ZIP ------------------------------------------------------------------------
ok('crc32 of "123456789" is cbf43926', crc32(new TextEncoder().encode('123456789')).toString(16) === 'cbf43926')
ok('crc32 matches node zlib', crc32(new Uint8Array([0, 1, 2, 250, 255])) === zlib.crc32(Buffer.from([0, 1, 2, 250, 255])))

// readZip: the stored entries of a ZIP via its central directory.
function readZip(buf) {
  const v = new DataView(buf.buffer, buf.byteOffset, buf.byteLength)
  const end = buf.byteLength - 22
  if (v.getUint32(end, true) !== 0x06054b50) throw new Error('no end record')
  const count = v.getUint16(end + 10, true)
  let o = v.getUint32(end + 16, true)
  const out = []
  for (let i = 0; i < count; i++) {
    if (v.getUint32(o, true) !== 0x02014b50) throw new Error('bad central header')
    const crc = v.getUint32(o + 16, true)
    const size = v.getUint32(o + 20, true)
    const nlen = v.getUint16(o + 28, true)
    const local = v.getUint32(o + 42, true)
    const name = new TextDecoder().decode(buf.subarray(o + 46, o + 46 + nlen))
    if (v.getUint32(local, true) !== 0x04034b50) throw new Error('bad local header')
    const start = local + 30 + v.getUint16(local + 26, true) + v.getUint16(local + 28, true)
    out.push({ name, crc, bytes: buf.subarray(start, start + size) })
    o += 46 + nlen
  }
  return out
}
const files = [{ name: 'a.jpg', bytes: new Uint8Array([1, 2, 3, 4]) }, { name: 'c.jpg', bytes: new Uint8Array(1000).fill(7) }]
let entries = []
try { entries = readZip(handoverZip(files)) } catch (e) { entries = [{ name: String(e) }] }
ok('the ZIP holds exactly the picked files, byte for byte, with their CRC', entries.length === 2 &&
  entries.every((e, i) => e.name === files[i].name && e.crc === crc32(files[i].bytes) &&
    Buffer.compare(Buffer.from(e.bytes), Buffer.from(files[i].bytes)) === 0), JSON.stringify(entries.map((e) => e.name)))

// --- an apex photo becomes this host's own path (R7 W1: tenant CSP img-src 'self')
const here = 'https://t1.example.com/tenant-settings/general'
ok('an apex /blog/img/ photo becomes the same-origin path', handoverSameOrigin('https://example.com/blog/img/a%20b.webp', here) === '/blog/img/a%20b.webp')
ok('a same-origin /blog/img/ photo keeps its path', handoverSameOrigin('https://t1.example.com/blog/img/a.jpg', here) === '/blog/img/a.jpg')
ok('a photo outside /blog/img/ is left as it is', handoverSameOrigin('https://cdn.example.net/x/a.jpg', here) === 'https://cdn.example.net/x/a.jpg')
ok('a URL that does not parse is left as it is', handoverSameOrigin('http://[bad', here) === 'http://[bad')

const suite = runsInUnitSuite(import.meta.url)
ok('pnpm test runs marketing-handover.test.mjs', suite.ok, suite.why)

if (failed) {
  console.log(`\n${failed} failed`)
  process.exit(1)
}
console.log('\nall passed')
