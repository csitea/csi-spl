<!-- HUM-10 (t1 05e0fa03): "the users should be able to set the load per box
     from the boxes view", "only the admins should be able to set ... this
     load" and "per box settings should overwrite the values per tenant".
     This box's own low / high band (rdb 0134), on its Boxes page. The same
     GET/PATCH /v1/operator/fleet-load as Settings -> Fleet load
     (FleetLoadCard.vue): the hub row is the one copy, so an edit here shows
     there and back. Shown only when that GET succeeds: a 403
     operator.workspaces (not the operator workspace's admin) hides it, as the
     settings card is hidden. Save re-reads the row first and changes only this
     box's entry (utils/fleet-load.mjs fleetBoxBandPatch), keeping the box's own
     runner CPU cap (rdb 0152), which is shown here when set. Lazy: its own chunk. -->
<template>
  <section
    v-if="state === 'ready' && view"
    class="box-band"
    data-test="box-band"
    :data-own="own ? '1' : '0'"
    :aria-label="t('boxes.band_title')"
  >
    <h3>{{ t('boxes.band_title') }}</h3>
    <p v-if="own" class="box-band__src" data-test="box-band-own">{{ t('boxes.band_own', { low: view.low, high: view.high }) }}</p>
    <p v-else class="muted box-band__src" data-test="box-band-fleet">{{ t('boxes.band_fleet', { low: view.low, high: view.high }) }}</p>
    <p v-if="cpu !== null" class="muted" data-test="box-band-cpu">{{ t('boxes.band_cpu', { n: cpu }) }}</p>
    <p v-if="pct !== null" class="muted" data-test="box-band-now">{{ t('boxes.band_now', { pct }) }}</p>
    <div class="box-band__marks">
      <label>
        <span>{{ t('tenant_settings.fleet_load_low') }}</span>
        <input
          :value="low"
          type="number"
          min="1"
          max="99"
          step="1"
          inputmode="numeric"
          autocomplete="off"
          data-test="box-band-low"
          @input="low = num(($event.target as HTMLInputElement).value)"
        >
      </label>
      <label>
        <span>{{ t('tenant_settings.fleet_load_high') }}</span>
        <input
          :value="high"
          type="number"
          min="2"
          max="100"
          step="1"
          inputmode="numeric"
          autocomplete="off"
          data-test="box-band-high"
          @input="high = num(($event.target as HTMLInputElement).value)"
        >
      </label>
    </div>
    <div class="box-band__actions">
      <button type="button" class="btn" :disabled="saving || !dirty" data-test="box-band-save" @click="save">
        {{ t('tenant_settings.save') }}
      </button>
      <button type="button" class="btn ghost" :disabled="saving || !own" data-test="box-band-reset" @click="reset">
        {{ t('boxes.band_reset') }}
      </button>
    </div>
    <p class="muted box-band__who" data-test="box-band-who">{{ t('boxes.band_who') }}</p>
    <p v-if="notice" class="box-band__ok" role="status" data-test="box-band-notice">{{ notice }}</p>
    <p v-if="error" class="box-band__err" role="alert" data-test="box-band-error">{{ error }}</p>
  </section>
  <!-- the probe settled and this viewer may not edit: no block (a test hook) -->
  <span v-else-if="state === 'hidden'" hidden data-test="box-band-hidden" />
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import {
  boxLoadPct,
  fleetBandOk,
  fleetBoxBandOf,
  fleetBoxBandPatch,
  fleetBoxCpuOf,
  fleetLoadForbidden,
  fleetLoadStatusDetail,
  normalizeFleetLoad,
} from '~/utils/fleet-load.mjs'
import type { FleetLoadView } from '~/utils/fleet-load.mjs'

const props = defineProps<{ box: string, sample: unknown }>()

type FleetApi = {
  getFleetLoad: () => Promise<unknown>
  patchFleetLoad: (patch: Record<string, unknown>) => Promise<unknown>
}

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi() as unknown as FleetApi

const state = ref<'loading' | 'hidden' | 'ready'>('loading')
const view = ref<FleetLoadView | null>(null)
const low = ref<number | ''>('')
const high = ref<number | ''>('')
const saving = ref(false)
const notice = ref('')
const error = ref('')

const own = computed(() => fleetBoxBandOf(view.value, props.box))
const cpu = computed(() => fleetBoxCpuOf(view.value, props.box))
const pct = computed(() => boxLoadPct(props.sample))
const dirty = computed(() => {
  const v = view.value
  if (!v) return false
  const cur = own.value || { low: v.low, high: v.high }
  return Number(low.value) !== cur.low || Number(high.value) !== cur.high
})

function num(raw: string): number | '' {
  return raw === '' ? '' : Number(raw)
}

/* the marks show this box's band in force: its own, else the fleet's */
function take(next: FleetLoadView) {
  view.value = next
  const b = fleetBoxBandOf(next, props.box) || { low: next.low, high: next.high }
  low.value = b.low
  high.value = b.high
}

function failed(e: unknown): string {
  if (fleetLoadForbidden(e)) return t('boxes.band_who')
  return fleetLoadStatusDetail(e) || (e as { detail?: string }).detail || t('tenant_settings.error.generic')
}

/* read the row afresh, then change only this box: an edit made on the
   settings page since this page opened is kept */
async function write(band: { low: number, high: number } | null) {
  notice.value = ''
  error.value = ''
  saving.value = true
  try {
    const fresh = normalizeFleetLoad(await api.getFleetLoad())
    const body = fleetBoxBandPatch(fresh, props.box, band)
    take(Object.keys(body).length ? normalizeFleetLoad(await api.patchFleetLoad(body)) : fresh)
    notice.value = t('tenant_settings.saved')
  } catch (e) {
    error.value = failed(e)
  } finally {
    saving.value = false
  }
}

async function save() {
  const band = { box: props.box, low: Number(low.value), high: Number(high.value) }
  if (low.value === '' || high.value === '' || !fleetBandOk(band)) {
    notice.value = ''
    error.value = t('tenant_settings.fleet_load_band_bad')
    return
  }
  await write({ low: band.low, high: band.high })
}

async function reset() {
  await write(null)
}

let seq = 0
async function load() {
  const mine = ++seq
  state.value = 'loading'
  notice.value = ''
  error.value = ''
  try {
    const next = normalizeFleetLoad(await api.getFleetLoad())
    if (mine !== seq) return
    take(next)
    state.value = 'ready'
  } catch {
    /* a 403 (not the operator admin) or no fleet load on this hub: no block */
    if (mine === seq) state.value = 'hidden'
  }
}

watch(() => props.box, () => { void load() }, { immediate: true })
</script>

<style scoped>
.box-band h3 { margin: 0 0 6px; font-size: 0.9rem; }
.box-band p { margin: 0 0 4px; overflow-wrap: anywhere; }
.box-band__src { font-weight: 600; }
.box-band__marks { display: flex; flex-wrap: wrap; gap: 8px 14px; margin: 6px 0 8px; }
.box-band__marks label { display: flex; flex-direction: column; gap: 2px; font-size: 0.8125rem; color: var(--color-muted); }
.box-band__marks input {
  width: 6em;
  max-width: 100%;
  min-width: 0;
  padding: 4px 6px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.box-band__actions { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 6px; }
.box-band__who { font-size: 0.78rem; }
.box-band__ok { color: var(--color-ok); }
.box-band__err { color: var(--color-danger); }
@media (max-width: 820px) {
  .box-band__marks input { min-height: var(--tap, 44px); }
  .box-band__actions .btn { min-height: var(--tap, 44px); }
}
</style>
