<!-- specs/054 (owner 18597eaa: "A small modal dialog should pop-up which will
     allow for the drop box picking a person to act as"): the "Act as…" picker
     opened from the avatar menu. A searchable drop-down of the members the
     reader may act as (the ceiling: never self, never the owner, and an admin
     never a peer admin), plus Act as / Cancel. The hub re-checks the permission
     and the ceiling on start; this only offers eligible people. -->
<template>
  <UiDialog :open="open" size="md" :title="t('act_as.dialog_title')" @update:open="emit('update:open', $event)">
    <div class="actas-pick">
      <p class="actas-pick__hint">{{ t('act_as.hint') }}</p>
      <label class="actas-pick__field">
        <span>{{ t('act_as.search') }}</span>
        <input
          ref="searchEl"
          v-model="query"
          type="text"
          autocomplete="off"
          data-test="act-as-search"
          :placeholder="t('act_as.search')"
        >
      </label>
      <label class="actas-pick__field">
        <span class="sr-only">{{ t('act_as.dialog_title') }}</span>
        <select v-model="picked" data-test="act-as-select" :size="Math.min(Math.max(shown.length, 2), 8)">
          <option v-for="m in shown" :key="m.humanId" :value="m.humanId" :data-test="'act-as-option-' + m.humanId">
            {{ label(m) }}
          </option>
        </select>
      </label>
      <p v-if="!loading && eligible.length === 0" class="actas-pick__empty" data-test="act-as-none">{{ t('act_as.none') }}</p>
      <p v-if="error" class="actas-pick__error" role="alert" data-test="act-as-error">{{ error }}</p>
    </div>
    <template #footer>
      <button type="button" class="btn ghost" data-test="act-as-cancel" @click="emit('update:open', false)">
        {{ t('common.cancel') }}
      </button>
      <button type="button" class="btn" :disabled="!picked || busy" data-test="act-as-confirm" @click="confirm">
        {{ t('act_as.confirm') }}
      </button>
    </template>
  </UiDialog>
</template>

<script setup lang="ts">
import UiDialog from '~/components/UiDialog.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAccessStore } from '~/stores/access'
import { MEMBERS_IMPERSONATE } from '~/utils/access.mjs'
import { memberLabel, normalizeDirectory } from '~/utils/tenant-users.mjs'
import type { UserMember } from '~/utils/tenant-users.mjs'

const props = defineProps<{ open: boolean }>()
const emit = defineEmits<{ 'update:open': [boolean] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const auth = useAuthClient()
const access = useAccessStore()
const localePath = useLocalePath()

const members = ref<UserMember[]>([])
const loading = ref(false)
const busy = ref(false)
const error = ref('')
const query = ref('')
const picked = ref('')
const searchEl = ref<HTMLInputElement | null>(null)

const myRole = computed(() => access.me?.role || '')
// The ceiling, client side: never yourself, never the owner; an admin may not
// act as a peer admin (a biz_owner may). The hub is the real control.
const eligible = computed(() => members.value.filter((m) => {
  if (m.you || !m.manageable || m.role === 'biz_owner') return false
  if (m.role === 'admin' && myRole.value === 'admin') return false
  return true
}))
const shown = computed(() => {
  const q = query.value.trim().toLowerCase()
  if (!q) return eligible.value
  return eligible.value.filter((m) => label(m).toLowerCase().includes(q) || m.humanId.toLowerCase().includes(q))
})

function label(m: UserMember) {
  return memberLabel(m)
}

async function fetchMembers() {
  loading.value = true
  error.value = ''
  try {
    const dir = normalizeDirectory(await api.listTenantUsers())
    members.value = dir.members
  } catch {
    error.value = t('act_as.load_failed')
  } finally {
    loading.value = false
  }
}

watch(() => props.open, (v) => {
  if (!v) return
  query.value = ''
  picked.value = ''
  error.value = ''
  void fetchMembers()
  void nextTick(() => searchEl.value?.focus())
}, { immediate: true })

// Keep a valid selection as the filter narrows.
watch(shown, (list) => {
  if (picked.value && !list.some((m) => m.humanId === picked.value)) picked.value = ''
})

async function confirm() {
  if (!picked.value || busy.value) return
  if (!access.can(MEMBERS_IMPERSONATE)) { error.value = t('act_as.forbidden'); return }
  busy.value = true
  error.value = ''
  try {
    const res = await auth.actAsStart(picked.value)
    if (!res || !res.ok) {
      error.value = res && res.error === 'forbidden' ? t('act_as.forbidden') : t('act_as.load_failed')
      return
    }
    // The cookie (or the mock) is now the clone: a full reload re-inits every
    // store as the clone and shows the "Acting as X" banner.
    if (import.meta.client) window.location.assign(localePath('/lobby'))
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.actas-pick {
  display: flex;
  flex-direction: column;
  gap: var(--spacing-md);
  min-width: 0;
}
.actas-pick__hint { margin: 0; color: var(--color-muted); }
.actas-pick__field {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 0;
}
.actas-pick__field input,
.actas-pick__field select {
  max-width: 100%;
  min-width: 0;
  padding: 6px 8px;
  background: var(--color-surface);
  color: var(--color-fg);
  border: 1px solid var(--color-border-strong);
}
.actas-pick__empty { margin: 0; color: var(--color-muted); }
.actas-pick__error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
.sr-only {
  position: absolute;
  width: 1px; height: 1px;
  padding: 0; margin: -1px;
  overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0;
}
@media (max-width: 820px) {
  .actas-pick__field input,
  .actas-pick__field select { font-size: max(16px, 1rem); }
}
</style>
