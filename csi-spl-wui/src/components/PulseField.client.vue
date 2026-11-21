<!-- Spec 111 section 12 (SPL-6140, owner HUM-10 t1 594bf36a): the pulsating
     colour field behind the blog and the sign-in page. A field of short
     dashes, each pointing away from a centre that drifts and leans toward the
     pointer, sized by a ring around that centre (thin at the centre, where
     the content is, and at the corners) and by a wave that runs outward, the
     pulse. The colours run across the theme's own accent tokens and are read
     again when the theme changes.
     Cheap by construction: canvas 2D, client-only and lazy (`<LazyPulseField>`
     in the two pages, so it is not in the initial JS of `/`), at most 900
     dashes, DPR capped at 2, about 30 frames a second, stopped while the tab
     is hidden or the canvas is off screen. Under prefers-reduced-motion:
     reduce it draws one still frame and runs no frame loop.
     Never in the way: aria-hidden, pointer-events none, behind the content
     (z-index -1 inside the page's own stacking context). -->
<template>
  <canvas ref="el" class="pulse-field" aria-hidden="true" data-test="pulse-field" :data-state="state" />
</template>

<script setup lang="ts">
import {
  mixPulseStops, placePulseDashes, pulseDpr, pulseRingWeight, readPulseColors,
} from '~/utils/pulse-field.mjs'

type Dash = { x: number, y: number, phase: number }
type Rgb = number[]
/** The canvas carries its frame count, for the e2e (no DOM write per frame). */
type FieldCanvas = HTMLCanvasElement & { pulseFrames?: number }

const BUCKETS = 16
const FRAME_MS = 33
const DASH_LEN = 7
const DASH_W = 2

const el = ref<FieldCanvas | null>(null)
const state = ref<'idle' | 'running' | 'paused' | 'static'>('idle')

let ctx: CanvasRenderingContext2D | null = null
let dashes: Dash[] = []
let stops: Rgb[] | null = null
let w = 0
let h = 0
let raf = 0
let last = 0
let t0 = 0
let onScreen = true
const pointer = { x: 0.5, y: 0.5, active: false }
const centre = { x: 0.5, y: 0.5 }
const cleanups: Array<() => void> = []

const reduced = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches
const alpha = () => (document.documentElement.getAttribute('data-theme') || 'dark').startsWith('light') ? 0.5 : 0.62

function readColors() {
  const css = getComputedStyle(document.documentElement)
  stops = readPulseColors((name: string) => css.getPropertyValue(name))
}

function resize() {
  const c = el.value
  if (!c) return
  const dpr = pulseDpr(window.devicePixelRatio)
  w = c.clientWidth
  h = c.clientHeight
  c.width = Math.round(w * dpr)
  c.height = Math.round(h * dpr)
  ctx = c.getContext('2d')
  ctx?.setTransform(dpr, 0, 0, dpr, 0, 0)
  dashes = placePulseDashes(w, h)
}

/** Where the centre is at time s: a slow wander, eased toward the pointer. */
function moveCentre(s: number) {
  const wx = 0.5 + Math.sin(s * 0.13) * 0.12
  const wy = 0.5 + Math.cos(s * 0.11) * 0.1
  const tx = pointer.active ? wx * 0.6 + pointer.x * 0.4 : wx
  const ty = pointer.active ? wy * 0.6 + pointer.y * 0.4 : wy
  centre.x += (tx - centre.x) * 0.04
  centre.y += (ty - centre.y) * 0.04
}

/** One dash as a rotated bar added to `path`: its long side points away from the centre. */
function addDash(path: Path2D, x: number, y: number, a: number, k: number) {
  const len = DASH_LEN * k
  const wid = DASH_W * Math.max(0.6, k)
  const ux = Math.cos(a) * len / 2
  const uy = Math.sin(a) * len / 2
  const vx = -Math.sin(a) * wid / 2
  const vy = Math.cos(a) * wid / 2
  path.moveTo(x - ux - vx, y - uy - vy)
  path.lineTo(x + ux - vx, y + uy - vy)
  path.lineTo(x + ux + vx, y + uy + vy)
  path.lineTo(x - ux + vx, y - uy + vy)
  path.closePath()
}

/** Draw the field at time s (seconds). The dashes are batched into one path per colour bucket. */
function draw(s: number) {
  if (!ctx || !stops) return
  ctx.clearRect(0, 0, w, h)
  const cx = centre.x * w
  const cy = centre.y * h
  const reach = Math.hypot(w, h) / 2
  const paths = Array.from({ length: BUCKETS }, () => new Path2D())
  for (const d of dashes) {
    const dx = d.x - cx
    const dy = d.y - cy
    const dist = Math.hypot(dx, dy)
    const pulse = 0.55 + 0.45 * Math.sin(d.phase + s * 1.6 - dist * 0.012)
    const k = pulseRingWeight(dist, reach) * pulse
    if (k < 0.12) continue
    const a = Math.atan2(dy, dx) + Math.sin(d.phase + s * 0.7) * 0.25
    const p = 0.5 + 0.5 * Math.sin(Math.atan2(dy, dx) + s * 0.25 + d.x * 0.002)
    addDash(paths[Math.min(BUCKETS - 1, Math.floor(p * BUCKETS))], d.x, d.y, a, k)
  }
  ctx.globalAlpha = alpha()
  paths.forEach((path, i) => {
    const [r, g, b] = mixPulseStops(stops as Rgb[], (i + 0.5) / BUCKETS)
    ctx!.fillStyle = `rgb(${r}, ${g}, ${b})`
    ctx!.fill(path)
  })
}

function frame(now: number) {
  raf = requestAnimationFrame(frame)
  if (now - last < FRAME_MS) return
  last = now
  const c = el.value
  if (c) c.pulseFrames = (c.pulseFrames || 0) + 1
  const s = (now - t0) / 1000
  moveCentre(s)
  draw(s)
}

function stop(next: 'paused' | 'static') {
  if (raf) cancelAnimationFrame(raf)
  raf = 0
  state.value = next
}

/** Run the loop when it may run; else one still frame (reduced motion) or a pause. */
function sync() {
  if (reduced()) {
    stop('static')
    draw(0)
    return
  }
  if (document.hidden || !onScreen) return stop('paused')
  if (raf) return
  state.value = 'running'
  raf = requestAnimationFrame(frame)
}

function listen(target: EventTarget, type: string, fn: EventListener) {
  target.addEventListener(type, fn, { passive: true })
  cleanups.push(() => target.removeEventListener(type, fn))
}

function watchTheme() {
  const mo = new MutationObserver(() => { readColors(); if (state.value !== 'running') draw(0) })
  mo.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'class'] })
  cleanups.push(() => mo.disconnect())
}

function watchPlace(c: HTMLCanvasElement) {
  const ro = new ResizeObserver(() => { resize(); if (state.value !== 'running') draw(0) })
  ro.observe(c)
  const io = new IntersectionObserver((entries) => {
    onScreen = entries.some((e) => e.isIntersecting)
    sync()
  })
  io.observe(c)
  cleanups.push(() => { ro.disconnect(); io.disconnect() })
}

/* Start on the canvas, not on mount: the client-only wrapper mounts this
   component behind a placeholder first, so the canvas is not there yet when
   onMounted runs. */
function start(c: FieldCanvas) {
  c.pulseFrames = 0
  t0 = performance.now()
  readColors()
  resize()
  watchTheme()
  watchPlace(c)
  listen(document, 'visibilitychange', sync)
  listen(window, 'pointermove', ((e: PointerEvent) => {
    pointer.x = e.clientX / Math.max(1, window.innerWidth)
    pointer.y = e.clientY / Math.max(1, window.innerHeight)
    pointer.active = true
  }) as EventListener)
  const mq = window.matchMedia('(prefers-reduced-motion: reduce)')
  listen(mq, 'change', sync)
  sync()
}

let started = false
watch(el, (c) => {
  if (!c || started) return
  started = true
  start(c)
}, { flush: 'post', immediate: true })

onBeforeUnmount(() => {
  stop('paused')
  cleanups.splice(0).forEach((fn) => fn())
})
</script>

<style scoped>
.pulse-field {
  position: fixed;
  inset: 0;
  z-index: -1;
  display: block;
  width: 100%;
  height: 100%;
  pointer-events: none;
}
</style>
