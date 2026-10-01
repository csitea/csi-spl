<!-- CLE-77888 (owner, t1 topic 1701ae89, 2026-10-01): "the last 5mm [strip]
     at the bottom should contain the connectivity icon, the bell icon and the
     note icon and the version icon as they are in the desktop app" - "the
     bottom bar will get as a whole some 5mm upper, but its content should not
     change". Phones only (<= 820 px; the layout mounts it there): the desktop
     sidebar footer's row - connection dot, bell, note, version - as a thin
     strip UNDER the docked composer, which sits on top of it
     (useStatusStrip). Same actions as the desktop: the bell and the note are
     the very same NotificationCenter buttons; the dot's and the version's
     hover cards open on a tap, since a touch screen has no hover. It steps
     away while the on-screen keyboard is up (the composer then sits on the
     keyboard) and hides, keeping its height, while a sheet is open over the
     page, exactly as the dock does. -->
<template>
  <footer
    v-if="shown"
    ref="barEl"
    class="status-strip"
    data-test="status-strip"
    :data-yield="stack.sheetOpen.value ? 'true' : undefined"
  >
    <button
      type="button"
      class="status-strip__btn status-strip__health"
      data-test="status-strip-health"
      :title="healthTitle"
      :aria-label="healthTitle"
      :aria-expanded="open === 'health'"
      @click="toggle('health')"
    >
      <span class="status-strip__dot" :class="health" aria-hidden="true" />
    </button>
    <NotificationCenter placement="strip" />
    <button
      type="button"
      class="status-strip__btn status-strip__version"
      data-test="status-strip-version"
      :aria-label="versionText || undefined"
      :aria-expanded="open === 'version'"
      @click="toggle('version')"
    >
      <span class="status-strip__ver">{{ versionLabel }}</span>
    </button>
    <div v-if="open === 'health'" class="status-strip__card" role="status" data-test="status-strip-health-card">
      <ConnectionStatus />
    </div>
    <div v-else-if="open === 'version'" class="status-strip__card status-strip__card--end" role="tooltip" data-test="status-strip-version-card">
      <span class="status-strip__row">
        <span class="status-strip__sha">{{ buildCommit || versionLabel }}</span>
        <button
          v-if="buildCommit"
          type="button"
          class="status-strip__copy"
          data-test="status-strip-version-copy"
          :title="copied ? t('code.copied') : t('code.copy')"
          :aria-label="copied ? t('code.copied') : t('code.copy')"
          @click="copyCommit"
        >
          <UiIcon :name="copied ? 'check' : 'copy'" :size="15" />
          <span v-if="copied" aria-live="polite">{{ t('code.copied') }}</span>
        </button>
      </span>
      <span v-if="buildMeta" class="status-strip__meta">{{ buildMeta }}</span>
      <span v-if="newerLive" class="status-strip__newer" data-test="status-strip-version-newer">
        <span>{{ t('build.newer_live', { commit: newerLive }) }}</span>
        <button type="button" class="status-strip__reload" @click="reloadForBuild(buildWatch.live)">{{ t('build.reload') }}</button>
      </span>
    </div>
  </footer>
</template>

<script setup lang="ts">
import NotificationCenter from '@/components/NotificationCenter.vue'
import ConnectionStatus from '@/components/ConnectionStatus.vue'
import { useLive } from '~/composables/useLive'
import { useCopyText } from '~/composables/useCopyText'
import { useKeyboardInset } from '~/composables/useTouchUi'
import { useMobileStack } from '~/composables/useMobileStack'
import { setStatusStripHeight } from '~/composables/useStatusStrip'
import { reloadForBuild, useBuildWatch } from '~/composables/useBuildWatch'
import { connectionHealth } from '~/utils/channel-feed.mjs'
import { buildStampText, readBuildStamp, shortCommit } from '~/utils/build-stamp.mjs'
import { isNewer } from '~/utils/build-watch.mjs'

const { t } = useI18n({ useScope: 'global' })
const stack = useMobileStack()
const kbInset = useKeyboardInset()
/* the layout mounts it on a phone only; the keyboard up = the composer is on it */
const shown = computed(() => kbInset.value === 0)

/* the desktop footer's dot: the same state, the same words */
const liveState = useLive().state
const health = computed(() => connectionHealth(liveState.value))
const healthTitle = computed(() => t('sidebar.health_title', { state: t('sidebar.health.' + health.value) }))

/* the desktop footer's version card (ChannelSidebar), read the same way */
const config = useRuntimeConfig()
const version = computed(() => String(config.public.appVersion || 'v0.1.0-dev'))
const build = ref(null)
onMounted(async () => { build.value = await readBuildStamp() })
const buildWatch = useBuildWatch()
const running = computed(() => buildWatch.value.running
  ? { commit: buildWatch.value.running, built_at: String(config.public.buildAt || ''), run: String(config.public.buildRun || '') }
  : build.value)
const newerLive = computed(() => (isNewer(buildWatch.value.running, buildWatch.value.live) ? shortCommit(buildWatch.value.live) : ''))
const versionText = computed(() => buildStampText(version.value, running.value))
const versionLabel = computed(() => String(version.value || '').trim())
const buildCommit = computed(() => String((running.value as { commit?: string } | null)?.commit || '').trim())
const buildMeta = computed(() => {
  const b = running.value as { built_at?: string, run?: string } | null
  if (!b) return ''
  return [b.built_at || '', b.run ? `run ${b.run}` : ''].filter(Boolean).join(' · ')
})
const { copied: copiedId, copy: copyText } = useCopyText()
const copied = computed(() => copiedId.value === 'strip-commit')
function copyCommit() { void copyText(buildCommit.value, 'strip-commit') }

/* one card at a time; a tap outside the strip or Esc closes it, Back too */
const open = ref<'' | 'health' | 'version'>('')
const barEl = ref<HTMLElement | null>(null)
function close() { open.value = '' }
function toggle(which: 'health' | 'version') { open.value = open.value === which ? '' : which }
function onOutside(ev: Event) {
  const el = barEl.value
  if (el && ev.target instanceof Node && el.contains(ev.target)) return
  close()
}
function onEsc(ev: KeyboardEvent) { if (ev.key === 'Escape') close() }
watch(open, (o) => {
  if (o) {
    document.addEventListener('pointerdown', onOutside, true)
    document.addEventListener('keydown', onEsc)
  } else {
    document.removeEventListener('pointerdown', onOutside, true)
    document.removeEventListener('keydown', onEsc)
  }
})
stack.overlay(() => open.value !== '', close, { keepsDock: true })

/* its height (safe-area inset included) lifts the composer; 0 when gone */
let observer: ResizeObserver | null = null
watch(barEl, (el) => {
  observer?.disconnect()
  observer = null
  if (!el) {
    close()
    setStatusStripHeight(0)
    return
  }
  setStatusStripHeight(el.getBoundingClientRect().height)
  if (typeof ResizeObserver !== 'undefined') {
    observer = new ResizeObserver(() => setStatusStripHeight(el.getBoundingClientRect().height))
    observer.observe(el)
  }
})
onBeforeUnmount(() => {
  observer?.disconnect()
  setStatusStripHeight(0)
  document.removeEventListener('pointerdown', onOutside, true)
  document.removeEventListener('keydown', onEsc)
})
</script>

<style scoped>
/* ~5 mm (22 px) of row, then the home-indicator inset below it */
.status-strip {
  position: fixed;
  inset-inline: 0;
  bottom: 0;
  z-index: calc(var(--z-sticky, 40) + 10);
  box-sizing: border-box;
  display: flex;
  align-items: center;
  gap: 4px;
  height: calc(22px + env(safe-area-inset-bottom, 0px));
  padding: 0 calc(8px + env(safe-area-inset-right, 0px)) env(safe-area-inset-bottom, 0px) calc(8px + env(safe-area-inset-left, 0px));
  background: var(--color-sidebar);
  border-top: 1px solid var(--color-border);
  font-size: 0.75rem;
  color: var(--color-muted);
}
.status-strip[data-yield=true] { visibility: hidden; }
.status-strip__btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: 44px;
  height: 21px; /* the strip's 22 px less its top border */
  padding: 0 6px;
  border: 0;
  background: none;
  color: inherit;
  font: inherit;
  cursor: pointer;
}
.status-strip__dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--color-danger);
}
.status-strip__dot.ok { background: var(--color-ok); }
.status-strip__dot.warn { background: var(--color-muted); }
/* as on the desktop: the version is the row's last item, at its end */
.status-strip__version { margin-inline-start: auto; min-width: 0; }
.status-strip__ver { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.status-strip__card {
  position: absolute;
  bottom: calc(100% + 4px);
  inset-inline-start: 8px;
  display: flex;
  flex-direction: column;
  gap: 2px;
  box-sizing: border-box;
  width: max-content;
  max-width: calc(100vw - 16px);
  padding: 6px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface, var(--color-bg));
  box-shadow: 0 4px 14px rgba(0, 0, 0, 0.18);
  color: var(--color-fg);
  user-select: text;
  -webkit-user-select: text;
}
.status-strip__card--end { inset-inline-start: auto; inset-inline-end: 8px; font-family: var(--font-mono); }
.status-strip__row { display: flex; align-items: center; gap: 6px; }
.status-strip__sha { min-width: 0; overflow-wrap: anywhere; word-break: break-all; }
.status-strip__copy {
  display: inline-flex; align-items: center; justify-content: center; gap: 4px; flex: none;
  min-width: var(--tap, 44px); min-height: var(--tap, 44px); padding: 0 4px;
  font: inherit; font-family: var(--font-sans, inherit); font-size: 0.7rem;
  border: 1px solid transparent; border-radius: var(--radius-sm);
  background: transparent; color: var(--color-muted); cursor: pointer;
}
.status-strip__meta { color: var(--color-muted); overflow-wrap: anywhere; }
.status-strip__newer { display: flex; align-items: center; gap: 0.5rem; flex-wrap: wrap; color: var(--color-warn); }
.status-strip__reload { font: inherit; color: var(--color-accent); background: none; border: 0; min-height: 44px; text-decoration: underline; cursor: pointer; }
</style>
