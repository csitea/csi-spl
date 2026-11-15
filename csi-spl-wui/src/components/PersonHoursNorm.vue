<!-- People -> a member's card, spec 107 FR-41 (SPL-5558; owner HUM-10 t1
     59a7062f msg d26fd5e6: "settable per person via the persons section"):
     the member's own average hours per day, over the workspace's. Shown only
     to a holder of hours.norm (biz_owner, product_owner, admin), who reads and
     sets it through GET / PUT /v1/members/<id>/hours/norm. Typed as h:mm (or
     7.5); empty = the workspace's value, 0:00 = no average for this member. -->
<template>
  <form v-if="!forbidden" class="phn" data-test="person-hours-norm" @submit.prevent="save">
    <label class="phn-field">
      <span>{{ t('people.hours_norm') }}</span>
      <input
        v-model="text"
        type="text"
        inputmode="decimal"
        autocomplete="off"
        :placeholder="workspaceText"
        :disabled="loading || !!loadError"
        :aria-invalid="invalid ? 'true' : 'false'"
        data-test="person-hours-norm-input"
      >
      <small class="muted" data-test="person-hours-norm-hint">{{ t('people.hours_norm_hint', { workspace: workspaceText }) }}</small>
    </label>
    <p v-if="loadError" class="phn-error" role="alert">{{ loadError }}</p>
    <div class="phn-actions">
      <button type="submit" class="btn" :disabled="busy || loading || !!loadError || invalid || !dirty" data-test="person-hours-norm-save">{{ t('tenant_settings.save') }}</button>
      <p v-if="notice" class="phn-notice" role="status" data-test="person-hours-norm-notice">{{ notice }}</p>
      <p v-if="error || invalid" class="phn-error" role="alert" data-test="person-hours-norm-error">{{ invalid ? t('tenant_settings.hours_norm_invalid') : error }}</p>
    </div>
  </form>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { tenantSettingsErrorKey } from '~/utils/tenant-settings.mjs'
import { hoursHhmm } from '~/utils/hours-calendar.mjs'
import { hoursMemberNormCall, hoursNormOf, hoursNormParse } from '~/utils/hours-norm.mjs'

const props = defineProps<{ humanId: string }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

type MemberNorm = { norm_day_minutes?: unknown, workspace_norm_day_minutes?: unknown }

/** the stored override; null = none (the workspace's is in force) */
const stored = ref<number | null>(null)
const workspace = ref(0)
const text = ref('')
const loading = ref(true)
const loadError = ref('')
/** the hub refused hours.norm (the card showed before the reader's role loaded): hide */
const forbidden = ref(false)
const busy = ref(false)
const error = ref('')
const notice = ref('')

/** what the field means: null when empty (the workspace's), else minutes or NaN */
const parsed = computed(() => (text.value.trim() === '' ? null : hoursNormParse(text.value)))
const invalid = computed(() => Number.isNaN(parsed.value))
const dirty = computed(() => !invalid.value && parsed.value !== stored.value)
const workspaceText = computed(() => (workspace.value > 0 ? hoursHhmm(workspace.value) : t('people.hours_norm_no_workspace')))

function take(body: unknown) {
  const b = (body || {}) as MemberNorm
  const own = b.norm_day_minutes
  stored.value = own === null || own === undefined ? null : (Number(own) === 0 ? 0 : hoursNormOf(own) || null)
  workspace.value = hoursNormOf(b.workspace_norm_day_minutes)
  text.value = stored.value === null ? '' : hoursHhmm(stored.value)
}

async function load(member: string) {
  loading.value = true
  try {
    const body = await hoursMemberNormCall(api, member)
    if (member !== props.humanId) return
    take(body)
    loadError.value = ''
  } catch (e) {
    forbidden.value = (e as { status?: number })?.status === 403
    loadError.value = t(tenantSettingsErrorKey(e))
  } finally {
    loading.value = false
  }
}

async function save() {
  if (busy.value || !dirty.value) return
  busy.value = true
  error.value = ''
  notice.value = ''
  try {
    take(await hoursMemberNormCall(api, props.humanId, parsed.value))
    notice.value = t('tenant_settings.saved')
  } catch (e) {
    error.value = t(tenantSettingsErrorKey(e))
  } finally {
    busy.value = false
  }
}

watch(text, () => { notice.value = '' })
/* read once mounted: a value taken before the async card's input is in the
   page does not reach it (seen in Chrome: the field stayed empty). */
onMounted(() => { if (props.humanId) void load(props.humanId) })
watch(() => props.humanId, (member) => { if (member) void load(member) })
</script>

<style scoped>
.phn { display: flex; flex-direction: column; gap: 10px; min-width: 0; }
.phn-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.phn-field > span { font-size: 0.9rem; font-weight: 700; }
.phn-field input {
  max-width: 10ch;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.phn-actions { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
.phn-notice { margin: 0; color: var(--color-ok); }
.phn-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
@media (max-width: 820px) {
  .phn-field input { max-width: none; min-height: var(--tap, 44px); }
  .phn-actions .btn { min-height: var(--tap, 44px); padding-block: 0; }
}
</style>
