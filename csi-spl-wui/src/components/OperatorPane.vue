<!-- Spec 074 T008 (owner HUM-10, t1 aa35699c: "we need to create a new
     section on the right most pane"): the operator console. The third kind
     of the ONE right-pane section (utils/topic-pane.mjs), opened from the
     rail button only an admin of the operator workspace sees. It lists the
     instance's workspaces (search, status filter), creates one, suspends /
     resumes and archives (soft: suspend + archive, with a confirm).
     The hub's 403 operator.workspaces is the gate on every call; a 403 here
     hides the section. Loaded lazily: the shell's initial chunk stays put. -->
<template>
  <aside
    class="topic operator-pane"
    data-pane="topic"
    data-test="topic-section"
    data-section="operator"
    :aria-label="t('operator.title')"
  >
    <header>
      <MobileBack />
      <UiCloseButton side="start" class="icon-btn topic-close" data-test="operator-close" @click="pane.close()" />
      <strong class="topic-heading__title" data-test="operator-heading" :title="t('operator.title')">{{ t('operator.title') }}</strong>
      <UiCloseButton side="end" class="icon-btn topic-close" data-test="operator-close" @click="pane.close()" />
    </header>
    <div class="feed-body op-body" data-test="operator-section">
      <div class="op-tools">
        <input
          v-model="q"
          type="search"
          class="op-search"
          autocomplete="off"
          spellcheck="false"
          :placeholder="t('operator.search')"
          :aria-label="t('operator.search')"
          data-test="operator-search"
        >
        <select v-model="status" :aria-label="t('operator.status_label')" data-test="operator-status">
          <option value="">{{ t('operator.status_all') }}</option>
          <option v-for="s in OPERATOR_STATUSES" :key="s" :value="s">{{ t('operator.status_' + s) }}</option>
        </select>
        <button type="button" class="btn ghost" :aria-expanded="creating ? 'true' : 'false'" data-test="operator-create-open" @click="creating = !creating">
          {{ t('operator.new') }}
        </button>
      </div>

      <form v-if="creating" class="op-create" data-test="operator-create" @submit.prevent="create">
        <label class="op-field">
          <span>{{ t('operator.field_id') }}</span>
          <input v-model="draft.id" type="text" maxlength="32" autocomplete="off" spellcheck="false" required data-test="operator-create-id">
          <small class="muted">{{ t('operator.field_id_hint') }}</small>
        </label>
        <label class="op-field">
          <span>{{ t('operator.field_name') }}</span>
          <input v-model="draft.displayName" type="text" maxlength="80" autocomplete="off" data-test="operator-create-name">
        </label>
        <label class="op-field">
          <span>{{ t('operator.field_email') }}</span>
          <input v-model="draft.adminEmail" type="email" maxlength="320" autocomplete="off" data-test="operator-create-email">
        </label>
        <label class="op-field">
          <span>{{ t('operator.field_billing') }}</span>
          <select v-model="draft.billingStatus" data-test="operator-create-billing">
            <option v-for="b in OPERATOR_BILLING" :key="b" :value="b">{{ b }}</option>
          </select>
        </label>
        <div class="op-actions">
          <button type="submit" class="btn" :disabled="busy !== ''" data-test="operator-create-submit">{{ t('operator.create') }}</button>
          <button type="button" class="btn ghost" :disabled="busy !== ''" @click="creating = false">{{ t('operator.cancel') }}</button>
        </div>
      </form>

      <div v-if="rootKey" class="op-key" data-test="operator-root-key">
        <label class="op-field">
          <span>{{ t('operator.root_key') }}</span>
          <textarea :value="rootKey" readonly rows="2" spellcheck="false" />
        </label>
        <button type="button" class="btn ghost" @click="rootKey = ''">{{ t('operator.root_key_done') }}</button>
      </div>

      <p v-if="notice" class="op-notice" role="status" data-test="operator-notice">{{ notice }}</p>
      <p v-if="error" class="op-error" role="alert" data-test="operator-error">{{ error }}</p>
      <p v-if="loading && !pane.rows.length" class="muted">{{ t('common.loading') }}</p>

      <ul v-if="shown.length" class="op-list" data-test="operator-list">
        <li
          v-for="w in shown"
          :key="w.id"
          class="op-row"
          data-test="operator-row"
          :data-ws="w.id"
          :data-status="statusOf(w)"
        >
          <div class="op-row__head">
            <strong class="op-row__name">{{ w.displayName || w.id }}</strong>
            <span v-if="w.operator" class="op-badge op-badge--operator">{{ t('operator.operator_badge') }}</span>
            <span class="op-badge" :class="'op-badge--' + statusOf(w)" data-test="operator-row-status">{{ t('operator.status_' + statusOf(w)) }}</span>
          </div>
          <div class="op-row__meta muted">
            <code>{{ w.id }}</code>
            <span>{{ t('operator.billing', { status: w.billingStatus || '-' }) }}</span>
          </div>
          <div v-if="confirming === w.id" class="op-confirm" data-test="operator-archive-confirm">
            <p>{{ t('operator.archive_confirm', { name: w.displayName || w.id }) }}</p>
            <div class="op-actions">
              <button type="button" class="btn danger" :disabled="busy !== ''" data-test="operator-archive-yes" @click="archive(w)">{{ t('operator.archive') }}</button>
              <button type="button" class="btn ghost" :disabled="busy !== ''" data-test="operator-archive-no" @click="confirming = ''">{{ t('operator.cancel') }}</button>
            </div>
          </div>
          <div v-else-if="!w.operator" class="op-actions">
            <button
              v-if="statusOf(w) === 'active'"
              type="button"
              class="btn ghost"
              :disabled="busy !== ''"
              data-test="operator-suspend"
              @click="setSuspended(w, true)"
            >{{ t('operator.suspend') }}</button>
            <button
              v-else
              type="button"
              class="btn ghost"
              :disabled="busy !== ''"
              data-test="operator-resume"
              @click="setSuspended(w, false)"
            >{{ t('operator.resume') }}</button>
            <button
              v-if="statusOf(w) !== 'archived'"
              type="button"
              class="btn ghost danger"
              :disabled="busy !== ''"
              data-test="operator-archive"
              @click="confirming = w.id"
            >{{ t('operator.archive') }}</button>
          </div>
        </li>
      </ul>
      <p v-else-if="!loading" class="muted" data-test="operator-empty">{{ t('operator.empty') }}</p>
    </div>
    <PaneCollapseToggle pane="threads" />
  </aside>
</template>

<script setup lang="ts">
import PaneCollapseToggle from '~/components/PaneCollapseToggle.vue'
import { useOperatorPane } from '~/stores/operator-pane'
import { useSpoolApi } from '~/composables/useSpoolApi'
import {
  OPERATOR_BILLING,
  OPERATOR_STATUSES,
  filterOperatorWorkspaces,
  normalizeOperatorWorkspaces,
  operatorCreateBody,
  operatorForbidden,
  operatorRootKey,
  operatorWorkspaceStatus,
  replaceOperatorWorkspace,
} from '~/utils/operator-console.mjs'
import type { OperatorWorkspace } from '~/utils/operator-console.mjs'

type OperatorApi = {
  listOperatorWorkspaces: () => Promise<unknown>
  createOperatorWorkspace: (body: Record<string, string>) => Promise<unknown>
  patchOperatorWorkspace: (id: string, patch: Record<string, unknown>) => Promise<unknown>
  archiveOperatorWorkspace: (id: string) => Promise<unknown>
}

const { t } = useI18n({ useScope: 'global' })
const pane = useOperatorPane()
const api = useSpoolApi() as unknown as OperatorApi

const q = ref('')
const status = ref('')
const creating = ref(false)
const draft = reactive({ id: '', displayName: '', adminEmail: '', billingStatus: 'manual' })
const busy = ref('')
const loading = ref(false)
const confirming = ref('')
const notice = ref('')
const error = ref('')
const rootKey = ref('')

const shown = computed(() => filterOperatorWorkspaces(pane.rows, { q: q.value, status: status.value }))
const statusOf = (w: OperatorWorkspace) => operatorWorkspaceStatus(w)
const nameOf = (w: OperatorWorkspace) => w.displayName || w.id

function failed(e: unknown) {
  /* a 403 here means this session is no longer the operator admin: hide the section */
  if (operatorForbidden(e)) {
    pane.visible = false
    pane.close()
    return
  }
  const err = e as { detail?: string, message?: string }
  error.value = err?.detail || err?.message || t('operator.load_failed')
}

async function reload() {
  loading.value = true
  error.value = ''
  try {
    pane.rows = normalizeOperatorWorkspaces(await api.listOperatorWorkspaces())
  } catch (e) {
    failed(e)
  } finally {
    loading.value = false
  }
}

/* one write at a time; its answer replaces that row */
async function write(id: string, call: () => Promise<unknown>, done: string) {
  busy.value = id
  notice.value = ''
  error.value = ''
  try {
    const body = await call() as { workspace?: unknown }
    if (body?.workspace) pane.rows = replaceOperatorWorkspace(pane.rows, body.workspace)
    notice.value = done
    return body
  } catch (e) {
    failed(e)
    return null
  } finally {
    busy.value = ''
  }
}

function setSuspended(w: OperatorWorkspace, suspended: boolean) {
  const done = t(suspended ? 'operator.suspended_notice' : 'operator.resumed_notice', { name: nameOf(w) })
  void write(w.id, () => api.patchOperatorWorkspace(w.id, { suspended }), done)
}

async function archive(w: OperatorWorkspace) {
  await write(w.id, () => api.archiveOperatorWorkspace(w.id), t('operator.archived_notice', { name: nameOf(w) }))
  confirming.value = ''
}

async function create() {
  const { body, error: bad } = operatorCreateBody(draft)
  if (!body) {
    error.value = t(bad || 'operator.error_id')
    return
  }
  rootKey.value = ''
  const out = await write(body.id || '', () => api.createOperatorWorkspace(body), t('operator.created', { id: body.id }))
  if (!out) return
  rootKey.value = operatorRootKey(out)
  Object.assign(draft, { id: '', displayName: '', adminEmail: '', billingStatus: 'manual' })
  creating.value = false
}

onMounted(() => { void reload() })
</script>

<style scoped>
.op-body {
  display: flex;
  flex-direction: column;
  gap: 12px;
  padding: 12px 14px;
  overflow-y: auto;
  min-height: 0;
  flex: 1 1 auto;
}
.op-tools { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.op-search { flex: 1 1 160px; min-width: 0; }
.op-tools input, .op-tools select, .op-field input, .op-field select {
  min-height: 36px;
  padding: 6px 10px;
  font-size: 0.875rem;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  color: var(--color-fg);
}
.op-create, .op-key {
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm, 8px);
  background: var(--color-bg-2);
}
.op-field { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
.op-field input, .op-field select, .op-field textarea { width: 100%; min-width: 0; box-sizing: border-box; }
.op-key textarea { font-family: var(--font-mono); overflow-wrap: anywhere; resize: vertical; }
.op-actions { display: flex; flex-wrap: wrap; gap: 8px; }
.op-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
.op-row {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 10px 12px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm, 8px);
  min-width: 0;
}
.op-row__head { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; min-width: 0; }
.op-row__name { overflow-wrap: anywhere; min-width: 0; }
.op-row__meta { display: flex; flex-wrap: wrap; gap: 10px; overflow-wrap: anywhere; }
.op-badge {
  font-size: 0.75rem;
  padding: 1px 8px;
  border-radius: var(--radius-pill);
  border: 1px solid var(--color-border);
  color: var(--color-muted);
}
.op-badge--active { color: var(--color-ok); border-color: var(--color-ok); }
.op-badge--suspended { color: var(--color-warn); border-color: var(--color-warn); }
.op-badge--archived { color: var(--color-muted); }
.op-badge--operator { color: var(--color-fg); border-color: var(--focus-ring); }
.op-confirm p { margin: 0 0 8px; }
.op-notice { margin: 0; color: var(--color-ok); }
.op-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; }
</style>
