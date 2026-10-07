<!-- spec 075 repo-edit §3, §4.3 (T12): "My edits", the member's repo doc
     edits and the ones their agents made for them (GET /v1/docs/edits?mine=1),
     newest first, each with its status chip: retry a failed edit here,
     resolve a conflict in the doc's conflict view. An agent's save for a
     member who never confirmed their published identity is refused (428):
     "Review my author identity" shows the §4.2 notice (RepoDocAuthorNotice)
     and records the consent, so the agent's next save goes through.
     A lazy chunk of the docs page (/docs?edits=mine). -->
<template>
  <section class="repo-mine" data-test="repo-edits" aria-labelledby="repo-mine-h">
    <div class="repo-mine__bar">
      <h3 id="repo-mine-h" class="repo-mine__h">{{ t('docs.repoEdit.mine.title') }}</h3>
      <NuxtLink :to="closeTo" class="btn ghost" data-test="repo-edits-close">{{ t('docs.repoEdit.mine.back') }}</NuxtLink>
    </div>
    <p class="muted repo-mine__lead">{{ t('docs.repoEdit.mine.lead') }}</p>
    <p v-if="message && !store.notice" class="repo-mine__error" role="alert" data-test="repo-edits-error">{{ message }}</p>
    <p v-if="state === 'loading'" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="state === 'failed'" class="muted" role="alert">{{ t('docs.load_failed') }}</p>
    <p v-else-if="!rows.length" class="muted" data-test="repo-edits-empty">{{ t('docs.repoEdit.mine.empty') }}</p>
    <ul v-else class="repo-mine__list">
      <li v-for="e in rows" :key="e.edit_id" class="repo-mine__row" data-test="repo-edits-row" :data-edit="e.edit_id" :data-status="e.status">
        <NuxtLink :to="localePath('/docs/' + e.path)" class="repo-mine__path" data-test="repo-edits-path">{{ e.path }}</NuxtLink>
        <span class="muted repo-mine__meta">
          <span data-test="repo-edits-by">{{ e.actor_kind === 'agent' ? t('docs.repoEdit.mine.by_agent', { agent: e.agent_id }) : t('docs.repoEdit.mine.by_you') }}</span>
          <span v-if="isoDateTime(e.created_at)"> · {{ isoDateTime(e.created_at) }}</span>
        </span>
        <span class="repo-mine__status">
          <RepoDocStatusChip :edit="e" :busy="store.busy" @retry="retry" @resolve="(id) => resolve(e.path, id)" />
          <span v-if="e.status === 'superseded'" class="muted">{{ t('docs.repoEdit.mine.superseded') }}</span>
          <span v-else-if="e.status === 'published'" class="muted">{{ t('docs.repoEdit.mine.published') }}</span>
        </span>
        <span v-if="e.status === 'failed' && e.last_error" class="repo-mine__reason" data-test="repo-edits-reason">{{ e.last_error }}</span>
      </li>
    </ul>
    <div class="repo-mine__identity">
      <p class="muted">{{ t('docs.repoEdit.mine.identity_lead') }}</p>
      <p v-if="store.confirmed" role="status" data-test="repo-edits-identity-ok">{{ t('docs.repoEdit.mine.identity_ok') }}</p>
      <button v-else type="button" class="btn ghost" data-test="repo-edits-identity" :disabled="store.busy" @click="store.reviewIdentity()">{{ t('docs.repoEdit.mine.identity') }}</button>
    </div>
    <RepoDocAuthorNotice :identity="store.notice" :busy="store.busy" :error="message" @cancel="store.dismissNotice()" @confirm="store.consent()" />
  </section>
</template>

<script setup lang="ts">
import RepoDocStatusChip from '~/components/RepoDocStatusChip.vue'
import RepoDocAuthorNotice from '~/components/RepoDocAuthorNotice.vue'
import { useRepoEditStore } from '~/stores/repoEdit'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { isPending } from '~/utils/repo-edit.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'

const props = defineProps<{ path: string }>()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const router = useRouter()
const store = useRepoEditStore()
const POLL_MS = useSpoolApi().mock ? 700 : 15000

const state = ref<'loading' | 'ready' | 'failed'>('loading')
const rows = computed(() => store.mine ?? [])
const message = computed(() => (store.error ? t(store.error.key, store.error.params) : ''))
/* back to the doc the list was opened over */
const closeTo = computed(() => localePath('/docs/' + props.path))

let timer: ReturnType<typeof setTimeout> | undefined
let alive = true
async function poll() {
  clearTimeout(timer)
  const ok = await store.loadMine()
  if (!alive) return
  if (state.value !== 'ready') state.value = ok ? 'ready' : 'failed'
  if (rows.value.some(isPending)) timer = setTimeout(() => void poll(), POLL_MS)
}
async function retry(id: string) {
  await store.retry(id)
  void poll()
}
function resolve(path: string, id: string) {
  void router.push({ path: localePath('/docs/' + path), query: { conflict: id } })
}
onMounted(() => { store.error = null; store.confirmed = false; void poll() })
onBeforeUnmount(() => {
  alive = false
  clearTimeout(timer)
  store.dismissNotice()
  store.error = null
})
</script>

<style scoped>
.repo-mine { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.repo-mine__bar { display: flex; align-items: center; justify-content: space-between; gap: 8px; flex-wrap: wrap; }
.repo-mine__h { margin: 0; font-size: 1.125rem; }
.repo-mine__lead { margin: 0; }
.repo-mine__error, .repo-mine__reason { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; font-size: 0.8125rem; }
.repo-mine__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; }
.repo-mine__row {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 4px 12px;
  padding: 10px 0;
  border-bottom: 1px solid var(--color-border);
  min-width: 0;
}
.repo-mine__path { color: var(--color-accent); text-decoration: underline; overflow-wrap: anywhere; }
.repo-mine__meta { grid-column: 1; font-size: 0.8125rem; }
.repo-mine__status { grid-column: 2; grid-row: 1 / span 2; display: inline-flex; align-items: center; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
.repo-mine__reason { grid-column: 1 / -1; }
.repo-mine__identity { display: flex; flex-direction: column; align-items: flex-start; gap: 8px; padding-top: 8px; }
.repo-mine__identity p { margin: 0; }
@media (max-width: 820px) {
  .repo-mine__row { grid-template-columns: minmax(0, 1fr); }
  .repo-mine__status { grid-column: 1; grid-row: auto; justify-content: flex-start; }
  .repo-mine .btn { min-height: 44px; }
}
</style>
