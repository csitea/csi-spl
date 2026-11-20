/*
 * SPL-5888 (spec 005 FR-020): Export to PDF. Loaded only on the menu click
 * (dynamic import), so neither this file nor MessagePrint.vue is in the
 * initial JS (specs/027). It renders the rows into a print-only block under
 * <body>, waits for the pictures and the markdown, names the document after
 * the file the PDF should get, and opens the browser's own print, where the
 * reader picks Save as PDF. The print stylesheet (MessagePrint.vue) shows only
 * that block while html carries `msg-printing`.
 */
import { h, nextTick, render, type AppContext } from 'vue'
import MessagePrint from '~/components/MessagePrint.vue'
import { printFileName, printImageSrcs } from '~/utils/msg-print'
import { isPreviewableImage, previewImageMime, sharedPreview } from '~/utils/file-preview'
import { isDownloadable } from '~/utils/view-api.mjs'
import { sha256Hex } from '~/utils/spool-client.mjs'
import { bytesToDataUri } from '~/utils/avatar'
import type { FileRef, SpoolMessage } from '~/types/spool'

/** the bounded waits: a picture or a markdown body that never settles prints as it is */
const IMG_WAIT_MS = 15000
const MD_WAIT_MS = 5000

export interface PrintApi { downloadFile: (id: string) => Promise<ArrayBuffer> }
export interface PrintJob {
  rows: SpoolMessage[]
  /** the topic title: the file name, and the heading of a whole-topic export */
  title: string
  /** one card's id: the file name gets its first 8 characters; absent = a whole topic */
  msgId?: string
  appContext: AppContext | null
  api: PrintApi
}

let host: HTMLElement | null = null
let restoreTitle = ''
/* removes the listeners that end the current print, if any */
let disarm: (() => void) | null = null
/* the newest export: an older one still waiting gives way, so there is one print block and one print */
let latest = 0

/* the same verified download (and page-wide cache) as FileAttachment.vue's preview */
async function imageSrc(f: FileRef, api: PrintApi): Promise<string> {
  if (!isDownloadable(f) || !isPreviewableImage(f.name, f.bytes)) return ''
  const id = String(f.file_id || f.sha256 || '')
  const want = String(f.sha256 || f.file_id || '')
  try {
    return await sharedPreview(want ? id + '\n' + want : '', async () => {
      const buf = await api.downloadFile(id)
      if (want && (await sha256Hex(buf)) !== want) return ''
      const type = previewImageMime(buf)
      return type ? bytesToDataUri(buf, type) : ''
    })
  } catch {
    return ''
  }
}

/* each download bounded: a hung /v1/files call prints the picture's name, never stalls the export */
function imageSrcs(rows: SpoolMessage[], api: PrintApi): Promise<Record<string, string>> {
  const files = rows.flatMap((m) => (Array.isArray(m.files) ? m.files : []) as FileRef[])
  return printImageSrcs(files, (f) => imageSrc(f, api), IMG_WAIT_MS)
}

function bounded(p: Promise<unknown>, ms: number): Promise<unknown> {
  return Promise.race([p, new Promise((r) => setTimeout(r, ms))])
}

/* every picture loaded or failed (a failed one shows its alt text), never forever */
function imagesSettled(root: HTMLElement): Promise<unknown> {
  const waits = [...root.querySelectorAll('img')].map((img) => (img.complete
    ? Promise.resolve()
    : new Promise<void>((done) => {
      img.addEventListener('load', () => done(), { once: true })
      img.addEventListener('error', () => done(), { once: true })
    })))
  return bounded(Promise.all(waits), IMG_WAIT_MS)
}

/* a markdown body renders after its lazy chunk loads (MarkdownBlock data-rendered) */
async function markdownSettled(root: HTMLElement): Promise<void> {
  const until = Date.now() + MD_WAIT_MS
  while (root.querySelector('[data-testid=md-block][data-rendered=false]') && Date.now() < until) {
    await new Promise((r) => setTimeout(r, 50))
  }
}

/** remove the print block and give the page its title back */
function clearPrint() {
  disarm?.()
  disarm = null
  document.documentElement.classList.remove('msg-printing')
  if (host) {
    render(null, host)
    host.remove()
    host = null
  }
  if (restoreTitle) document.title = restoreTitle
  restoreTitle = ''
}

/* the page events that mean the reader is back on the page after a phone's print */
const BACK_EVENTS = ['pointerdown', 'keydown'] as const

/*
 * SPL-6110 (owner HUM-10, t1 703f2ce5 msg 4460aad7: "On mobile, at least,
 * doesn't work"): a desktop's print returns when its dialog closes, and
 * afterprint ends the print there. A phone's (a coarse pointer) may return at
 * once and fire afterprint before the page is laid out for print, which took
 * the block away first. There the block (print-only, never on screen) stays
 * until the reader touches the page again, or the next export replaces it.
 */
function armClear() {
  const phone = typeof window.matchMedia === 'function' && window.matchMedia('(pointer: coarse)').matches
  const events: readonly string[] = phone ? BACK_EVENTS : ['afterprint']
  const end = () => clearPrint()
  for (const e of events) window.addEventListener(e, end, { capture: true, once: true })
  disarm = () => { for (const e of events) window.removeEventListener(e, end, { capture: true }) }
}

/**
 * render `job.rows` print-only, wait for pictures and markdown, then the
 * browser's print; null when a newer export started meanwhile (that one prints)
 */
export async function printMessages(job: PrintJob): Promise<HTMLElement | null> {
  const run = ++latest
  const srcs = await imageSrcs(job.rows, job.api)
  if (run !== latest) return null
  clearPrint()
  const el = document.createElement('div')
  el.className = 'msg-print-host'
  el.setAttribute('data-test', 'msg-print-host')
  document.body.appendChild(el)
  host = el
  const vnode = h(MessagePrint, { rows: job.rows, heading: job.msgId ? '' : job.title, srcs })
  vnode.appContext = job.appContext
  render(vnode, el)
  await nextTick()
  await markdownSettled(el)
  await imagesSettled(el)
  if (run !== latest) {
    /* a newer export took over; drop this block unless it already did */
    if (host === el) clearPrint()
    else { render(null, el); el.remove() }
    return null
  }
  restoreTitle = document.title
  document.title = printFileName(job.title, job.msgId)
  document.documentElement.classList.add('msg-printing')
  el.setAttribute('data-ready', 'true')
  armClear()
  window.print()
  return el
}
