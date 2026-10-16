<!-- Settings → Appearance → "Second currency" (spec 123 5.4, SPL-2199, owner
     HUM-10 t1 1b6f871f msg 44fef397: "In the settings of the system, the
     user should be able to configure another currency, and the default for
     this other currency should be euros. This should be in the personal
     settings"). Monitoring → Costs shows every cost in USD and in this
     currency, each day at its own rate. The list is the codes the hub holds
     rates for (GET /v1/tenant/fx/currencies); the pick is kept per workspace
     (PUT /api/v1/auth/preferences second_currency, like time_zone), and
     picking the default clears it. Optimistic like the time zone: the claim
     changes on pick and changes back with a status line when the hub
     refuses. tenant-costs.mjs loads on demand (its chunk rule). -->
<template>
  <div v-if="signedIn" class="cur-setting" data-test="second-currency-setting">
    <label :for="`${uid}-cur`" class="cur-setting__label">{{ t('settings.second_currency.label') }}</label>
    <select
      :id="`${uid}-cur`"
      class="cur-setting__select"
      :value="current"
      :disabled="saving"
      :aria-describedby="`${uid}-cur-hint`"
      data-test="second-currency-select"
      @change="pick(($event.target as HTMLSelectElement).value)"
    >
      <option v-for="c in list.currencies" :key="c" :value="c">{{ c === list.default ? t('settings.second_currency.default', { currency: c }) : c }}</option>
    </select>
    <p :id="`${uid}-cur-hint`" class="muted cur-setting__hint">{{ t('settings.second_currency.hint') }}</p>
    <p v-if="status" class="cur-setting__status" role="status" aria-live="polite" data-test="second-currency-status">{{ status }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useSettingSave } from '~/composables/useSettingSave'
import { useSpoolApi } from '~/composables/useSpoolApi'

type FxApi = { getFxCurrencies: () => Promise<unknown> }
type CurrencyList = { default: string, currencies: string[] }
/* saveViewPref's key list is typed in mjs-shims.d.ts; the PUT itself takes any key */
type SaveViewPref = (key: string, value: string | null) => Promise<{ ok: boolean }>

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const save = useAuthClient().saveViewPref as unknown as SaveViewPref
const { saving, status, run } = useSettingSave()

const uid = useId()
const signedIn = computed(() => session.state === 'in')
const DEFAULT = 'EUR'
const list = ref<CurrencyList>({ default: DEFAULT, currencies: [DEFAULT] })
const current = computed(() => String(session.claims?.second_currency || '').toUpperCase() || list.value.default)

/* the claim alone (no store method: the session store is first-screen code) */
function mirror(code: string | null) {
  if (session.claims) session.claims = { ...session.claims, second_currency: code }
}

function pick(want: string) {
  const before = session.claims?.second_currency ?? null
  const next = want && want !== list.value.default ? want : null
  if (next === before || (!next && !before)) return
  return run(async () => {
    mirror(next)
    const out = await save('second_currency', next)
    if (!out.ok) mirror(before)
    return { ok: out.ok, out }
  })
}

onMounted(async () => {
  const tc = await import('~/utils/tenant-costs.mjs')
  const keep = String(session.claims?.second_currency || '')
  try {
    list.value = tc.costCurrencyOptions(await (useSpoolApi() as unknown as FxApi).getFxCurrencies(), keep)
  } catch {
    /* no list: the default and the current pick stay pickable */
    list.value = tc.costCurrencyOptions(null, keep)
  }
})
</script>

<style scoped>
.cur-setting {
  display: grid;
  gap: 6px;
  min-width: 0;
  max-width: 100%;
}
.cur-setting__label { font-weight: 600; }
.cur-setting__select {
  min-height: var(--tap, 44px);
  max-width: 100%;
  min-width: 0;
}
.cur-setting__hint,
.cur-setting__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.cur-setting__status { color: var(--color-error); }
</style>
