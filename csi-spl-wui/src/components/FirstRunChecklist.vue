<!-- The first-run checklist (W15, spec 047, SPL-1172): on the home screen of
     a tenant's admin or business owner, the next 3 steps until the workspace
     is set up - invite a teammate, connect an agent, start a topic in
     #lobby. Each step reads done from what the hub already answers
     (utils/first-run.mjs); the card hides once all three are done, or when
     the viewer presses Hide (this browser, per tenant). Loaded lazily by
     pages/index.vue, only for a viewer who may open Tenant settings. -->
<template>
  <section v-if="shown" class="first-run" :class="{ 'first-run--chip': isChip }" aria-labelledby="first-run-h" data-test="first-run">
    <template v-if="isChip">
      <h3 id="first-run-h" class="first-run__chip-title">{{ t('first_run.chip') }}</h3>
      <button type="button" class="btn ghost first-run__hide" data-test="first-run-hide" @click="hide">{{ t('first_run.hide') }}</button>
    </template>
    <template v-else>
      <header class="first-run__head">
        <h3 id="first-run-h">{{ t('first_run.title') }}</h3>
        <button type="button" class="btn ghost first-run__hide" data-test="first-run-hide" @click="hide">{{ t('first_run.hide') }}</button>
      </header>
      <p class="muted first-run__intro">{{ t('first_run.intro') }}</p>
      <ol class="first-run__steps">
        <li
          v-for="(s, i) in steps"
          :key="s.id"
          class="first-run__step"
          :class="{ 'first-run__step--done': s.done }"
          :data-test="'first-run-step-' + s.id"
          :data-done="s.done ? 'true' : 'false'"
        >
          <span class="first-run__mark" aria-hidden="true">
            <UiIcon v-if="s.done" name="check" :size="16" />
            <template v-else>{{ i + 1 }}</template>
          </span>
          <span class="first-run__text">
            <NuxtLink :to="localePath(s.to)" class="first-run__link" :data-test="`first-run-link-${s.id}`">{{ t(`first_run.${s.id}`) }}</NuxtLink>
            <span class="muted first-run__hint">{{ s.done ? t('first_run.done') : t(`first_run.${s.id}_hint`) }}</span>
          </span>
        </li>
      </ol>
    </template>
  </section>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { firstRunHiddenKey, firstRunSteps, firstRunVisible } from '~/utils/first-run.mjs'

const props = defineProps<{ tenant: string, topics: number }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const api = useSpoolApi()

const members = ref<number | null>(null)
const invites = ref<number | null>(null)
const roster = ref<Record<string, string[]> | null>(null)
const hidden = ref(false)
const loaded = ref(false)

const steps = computed(() => firstRunSteps({ members: members.value, invites: invites.value, roster: roster.value, topics: props.topics }))
const isChip = computed(() => steps.value.some((s) => s.done))
const shown = computed(() => loaded.value && firstRunVisible({ canSetUp: true, hidden: hidden.value, steps: steps.value }))

function hide() {
  hidden.value = true
  try { localStorage.setItem(firstRunHiddenKey(props.tenant), '1') } catch { /* private mode: this page only */ }
}

onMounted(async () => {
  try { hidden.value = localStorage.getItem(firstRunHiddenKey(props.tenant)) === '1' } catch { /* shown */ }
  if (hidden.value) return
  const [dir, r] = await Promise.allSettled([api.listTenantUsers(), api.listRoster()])
  if (dir.status === 'fulfilled') {
    const b = (dir.value || {}) as { members?: unknown[], invites?: unknown[] }
    members.value = Array.isArray(b.members) ? b.members.length : null
    invites.value = Array.isArray(b.invites) ? b.invites.length : null
  }
  if (r.status === 'fulfilled') roster.value = ((r.value || {}) as { roster?: Record<string, string[]> }).roster || null
  loaded.value = true
})
</script>

<style scoped>
.first-run {
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md, 12px);
  background: var(--color-bg-2);
  padding: 12px 16px;
  margin: 0 0 12px;
  min-width: 0;
}
.first-run--chip {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 8px 12px;
  gap: 8px;
}
.first-run__chip-title {
  margin: 0;
  font-size: 0.875rem;
  font-weight: 500;
}
.first-run__head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.first-run__head h3 { margin: 0; font-size: 1rem; }
.first-run__intro { margin: 4px 0 10px; }
.first-run__steps { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
.first-run__step { display: flex; gap: 10px; align-items: flex-start; min-width: 0; }
.first-run__mark {
  flex: none;
  display: grid;
  place-items: center;
  width: 24px;
  height: 24px;
  border-radius: 50%;
  border: 1px solid var(--color-border-strong);
  font-size: 0.8125rem;
}
.first-run__step--done .first-run__mark { background: var(--color-ok); border-color: var(--color-ok); color: var(--color-bg); }
.first-run__step--done .first-run__link { text-decoration: line-through; }
.first-run__text { display: flex; flex-direction: column; min-width: 0; }
.first-run__link { font-weight: 600; overflow-wrap: anywhere; }
.first-run__hint { font-size: 0.8125rem; overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .first-run__hide { min-height: var(--tap, 44px); }
  .first-run__link { min-height: var(--tap, 44px); display: flex; align-items: center; }
}
</style>
