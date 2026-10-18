/*
 * ChannelSidebar's footer version (r13-04): the version and commit this tab
 * runs, its card (hover, tap, Esc, a click outside), the newer-build note, the
 * commit copy, and whether the footer row hosts the last-data clock.
 */
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch, type Ref } from 'vue'
import { buildStampText, readBuildStamp, shortCommit } from '~/utils/build-stamp.mjs'
import { displayVersion } from '~/utils/display-version.mjs'
import { isNewer } from '~/utils/build-watch.mjs'
import { useBuildWatch } from '~/composables/useBuildWatch'
import { useClockHost } from '~/composables/useClockHost'
import { useCopyText } from '~/composables/useCopyText'
import type { useMobileStack } from '~/composables/useMobileStack'

/* the version's card: open, close, placed above the version */
function useVsCard(mobileStack: ReturnType<typeof useMobileStack>, vsWrapEl: Ref<HTMLElement | null>) {
  /* the card also opens by a tap (touch has no hover) and closes on Esc */
  const vsOpen = ref(false)
  /* owner 2026-09-27 (topic 82b9c309): a click or tap anywhere outside the
     card closes it. Closing also drops the focus, since :focus-within would
     otherwise keep the card painted after vsOpen is false. */
  function closeVsPop() {
    vsOpen.value = false
    const wrap = vsWrapEl.value
    const active = typeof document !== 'undefined' ? document.activeElement : null
    if (wrap && active instanceof HTMLElement && wrap.contains(active)) active.blur()
  }
  function toggleVsPop(ev: Event) {
    /* SPL-1023: a press inside the card (select the hash, copy) keeps it */
    if (ev.target instanceof Element && ev.target.closest('.vs-pop')) return
    if (vsOpen.value) return closeVsPop()
    placeVsPop(ev)
    vsOpen.value = true
  }
  function onVsOutside(ev: Event) {
    const wrap = vsWrapEl.value
    if (wrap && ev.target instanceof Node && wrap.contains(ev.target)) return
    closeVsPop()
  }
  /* SPL-1023: Esc closes it wherever the focus is */
  function onVsEsc(ev: KeyboardEvent) {
    if (ev.key === 'Escape') closeVsPop()
  }
  watch(vsOpen, (open) => {
    if (typeof document === 'undefined') return
    if (open) {
      document.addEventListener('pointerdown', onVsOutside, true)
      document.addEventListener('keydown', onVsEsc)
    } else {
      document.removeEventListener('pointerdown', onVsOutside, true)
      document.removeEventListener('keydown', onVsEsc)
    }
  })
  onBeforeUnmount(() => {
    if (typeof document === 'undefined') return
    document.removeEventListener('pointerdown', onVsOutside, true)
    document.removeEventListener('keydown', onVsEsc)
  })
  /* SPL-1023: on a phone Back closes it first (SPL-994); a small card, so the dock stays */
  mobileStack.overlay(vsOpen, closeVsPop, { keepsDock: true })
  /* SPL-999: the sidebar clips (overflow: clip, 260 px), so the card is
     position: fixed: placed directly above the version, from the footer
     row's left edge, each time it opens, and pulled back so its right edge
     stays 8 px inside the screen */
  const vsPlace = ref<Record<string, string>>({})
  function placeVsPop(ev?: Event) {
    const wrap = (ev?.currentTarget as HTMLElement | null) || document.querySelector<HTMLElement>('[data-test=app-version-wrap]')
    const row = wrap?.closest('.foot-row')
    if (!wrap || !row) return
    const r = row.getBoundingClientRect()
    const card = wrap.querySelector<HTMLElement>('.vs-pop')
    const w = card ? card.offsetWidth : 0
    const left = Math.max(8, Math.min(r.left + 8, window.innerWidth - 8 - w))
    vsPlace.value = { '--vs-left': `${Math.round(left)}px`, '--vs-bottom': `${Math.round(window.innerHeight - wrap.getBoundingClientRect().top)}px` }
  }
  return { vsOpen, closeVsPop, toggleVsPop, placeVsPop, vsPlace }
}

function useFootClock(phone: Ref<boolean>, vsWrapEl: Ref<HTMLElement | null>) {
  const route = useRoute()
  /* be316fdc: the clock follows the version - here only while this row is
     drawn: not on a phone, not rail-only, not under the topic browser. A
     resize catches the rail / collapse, a route change the hidden sidebar. */
  const clockHost = useClockHost()
  const footRow = () => vsWrapEl.value?.closest<HTMLElement>('.foot-row') || null
  function measureFoot() {
    const el = footRow()
    const r = el?.getBoundingClientRect()
    clockHost.foot.value = Boolean(!phone.value && el && r && r.width > 0 && r.height > 0 && getComputedStyle(el).visibility === 'visible')
  }
  let footObserver: ResizeObserver | null = null
  function observeFoot() {
    footObserver?.disconnect()
    footObserver = null
    measureFoot()
    const el = footRow()
    if (typeof ResizeObserver !== 'undefined' && el) {
      footObserver = new ResizeObserver(measureFoot)
      footObserver.observe(el)
    }
  }
  onMounted(observeFoot)
  /* SPL-2435: a rail-only page does not mount the footer; observe the row
     that mounts when the reader leaves it, not only the first one */
  watch(vsWrapEl, observeFoot, { flush: 'post' })
  watch([() => route.fullPath, phone], () => nextTick(() => requestAnimationFrame(measureFoot)))
  onBeforeUnmount(() => {
    footObserver?.disconnect()
    clockHost.foot.value = false
  })
  return clockHost
}

export function useSidebarVersion(phone: Ref<boolean>, mobileStack: ReturnType<typeof useMobileStack>, vsWrapEl: Ref<HTMLElement | null>) {
  const config = useRuntimeConfig()
  const { vsOpen, closeVsPop, toggleVsPop, placeVsPop, vsPlace } = useVsCard(mobileStack, vsWrapEl)
  const releaseNotesOpen = ref(false)
  const clockHost = useFootClock(phone, vsWrapEl)
  const version = computed(() => String(config.public.appVersion || 'v0.1.0-dev'))
  /* the deployed stamp, read once, client only; null in lde and on any failure */
  const build = ref(null)
  onMounted(async () => { build.value = await readBuildStamp() })
  /* SPL-1006: the commit THIS tab runs (baked in at build time) wins over the
     deployed stamp, which is only the fallback where none is baked (lde) */
  const buildWatch = useBuildWatch()
  const running = computed(() => buildWatch.value.running
    ? { commit: buildWatch.value.running, built_at: String(config.public.buildAt || ''), run: String(config.public.buildRun || '') }
    : build.value)
  const newerLive = computed(() => (isNewer(buildWatch.value.running, buildWatch.value.live) ? shortCommit(buildWatch.value.live) : ''))
  const versionText = computed(() => buildStampText(displayVersion(version.value), running.value))
  /* owner, 2026-09-26: the version smaller, the commit smaller still, a tight gap */
  const versionLabel = computed(() => displayVersion(version.value))
  const buildCommit = computed(() => String((running.value as { commit?: string } | null)?.commit || '').trim())
  /* SPL-999: the code blocks' copy (with its insecure-origin fallback) */
  const { copied: vsCopiedId, copy: copyText } = useCopyText()
  const vsCopied = computed(() => vsCopiedId.value === 'commit')
  function copyCommit() { void copyText(buildCommit.value, 'commit') }
  const buildMeta = computed(() => {
    const b = running.value as { built_at?: string, run?: string } | null
    if (!b) return ''
    return [b.built_at || '', b.run ? `run ${b.run}` : ''].filter(Boolean).join(' · ')
  })
  return { buildWatch, newerLive, versionText, versionLabel, buildCommit, vsOpen, releaseNotesOpen, closeVsPop, toggleVsPop, placeVsPop, clockHost, vsPlace, vsCopied, copyCommit, buildMeta }
}
