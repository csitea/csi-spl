<!-- Spec 155 2.6 (SPL-2403, B5 SPL-4123): the Notes section, the person's
     own list (the realm, 2.2: the same list in every workspace). The sidebar
     keeps the icon rail only (ChannelSidebar notesRailOnly); this page is the
     list: New note, the filter box, the Archived switch, the Pinned group,
     then the rest. A row is /notes?note=<id>; the open note is B6's. -->
<template>
  <div class="feed-col notes-page" data-test="notes-page">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 class="notes-title" data-test="notes-heading">
        <UiIcon name="notes" :size="18" />
        <span>{{ t('notes.title') }}</span>
      </h2>
      <SectionClose side="end" />
    </header>
    <div class="feed-body notes-body">
      <p v-if="store.state === 'off'" class="muted" data-test="notes-off">{{ t('notes.off') }}</p>
      <template v-else>
        <div class="notes-bar">
          <button type="button" class="btn notes-bar__new" data-test="notes-new" :disabled="creating" @click="newNote">
            <UiIcon name="plus" :size="16" />
            <span>{{ t('notes.new') }}</span>
          </button>
          <input
            v-model="query"
            type="search"
            class="notes-bar__filter"
            data-test="notes-filter"
            :placeholder="t('notes.filter')"
            :aria-label="t('notes.filter')"
          >
          <button
            type="button"
            class="btn ghost notes-bar__archived"
            data-test="notes-archived"
            :aria-pressed="archived ? 'true' : 'false'"
            @click="archived = !archived"
          >{{ t('notes.archived') }}</button>
        </div>
        <p v-if="createFailed" class="notes-error" role="alert" data-test="notes-create-failed">{{ t('notes.create_failed') }}</p>
        <p v-if="store.state === 'failed'" class="notes-error" role="alert" data-test="notes-error">
          {{ t('notes.load_failed') }}
          <button type="button" class="btn ghost" data-test="notes-retry" @click="store.load()">{{ t('notes.retry') }}</button>
        </p>
        <p v-else-if="store.state === 'loading' || store.state === 'idle'" class="muted" data-test="notes-loading">{{ t('notes.loading') }}</p>
        <p v-else-if="!rows.length" class="muted" data-test="notes-empty">{{ t(emptyKey) }}</p>
        <template v-else>
          <section v-for="g in groups" :key="g.id" class="notes-group" :data-test="'notes-group-' + g.id">
            <h3 v-if="g.label" class="notes-group__head">{{ t(g.label) }}</h3>
            <ul class="notes-list" :aria-label="t('notes.list_label')">
              <li v-for="n in g.rows" :key="n.id" class="notes-row" data-test="notes-row" :data-note-id="n.id">
                <NuxtLink
                  class="notes-row__open"
                  :class="{ 'notes-row__open--current': openId === n.id }"
                  :to="{ path: localePath('/notes'), query: { note: n.id } }"
                  :aria-current="openId === n.id ? 'true' : undefined"
                  data-test="notes-open"
                >
                  <span class="notes-row__title">{{ rowTitle(n) }}</span>
                  <span v-if="n.title && n.snippet" class="notes-row__text muted">{{ n.snippet }}</span>
                  <span class="notes-row__meta muted">
                    <span v-if="n.items_total" :title="t('notes.items_hint', { done: n.items_done, total: n.items_total })" dir="ltr">{{ t('notes.items', { done: n.items_done, total: n.items_total }) }}</span>
                    <span v-if="n.link_count">{{ t('notes.links', { n: n.link_count }) }}</span>
                    <span dir="ltr">{{ t('notes.changed', { when: isoDateTime(n.updated_at) }) }}</span>
                  </span>
                </NuxtLink>
              </li>
            </ul>
          </section>
        </template>
      </template>
    </div>
  </div>
</template>

<script setup lang="ts">
import { filterNotes, useNotesStore } from '~/stores/notes'
import type { NoteSummary } from '~/stores/notes'
import { isoDateTime } from '~/utils/date-iso.mjs'

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const localePath = useLocalePath()
const store = useNotesStore()
const query = ref('')
const archived = ref(false)
const creating = ref(false)
const createFailed = ref(false)

useHead({ title: () => t('notes.title') })

const rows = computed(() => filterNotes(store.notes, query.value, archived.value))
/* 2.6: the Pinned group, then the rest; the Archived view is one list */
const groups = computed(() => {
  if (archived.value) return [{ id: 'archived', label: '', rows: rows.value }]
  const pinned = rows.value.filter((n) => n.pinned)
  const rest = rows.value.filter((n) => !n.pinned)
  if (!pinned.length) return [{ id: 'rest', label: '', rows: rest }]
  return [{ id: 'pinned', label: 'notes.pinned', rows: pinned }, ...(rest.length ? [{ id: 'rest', label: 'notes.others', rows: rest }] : [])]
})
const emptyKey = computed(() => (query.value.trim() ? 'notes.empty_filter' : archived.value ? 'notes.empty_archived' : 'notes.empty'))
const openId = computed(() => String(route.query.note || ''))

/** the title, else the first line of the text (2.6), else "Untitled note" */
function rowTitle(n: NoteSummary) {
  return n.title || n.snippet.split('\n')[0] || t('notes.untitled')
}

async function newNote() {
  creating.value = true
  createFailed.value = false
  const id = await store.create()
  creating.value = false
  if (!id) {
    createFailed.value = true
    return
  }
  archived.value = false
  query.value = ''
  await navigateTo({ path: localePath('/notes'), query: { note: id } })
}

/* 2.1: no live updates between tabs; the list is read again on focus */
function onFocus() {
  if (store.state === 'ready') void store.load()
}
onMounted(() => {
  void store.load()
  window.addEventListener('focus', onFocus)
})
onUnmounted(() => window.removeEventListener('focus', onFocus))
</script>

<style scoped>
.notes-title { display: inline-flex; align-items: center; gap: 8px; margin: 0; }
.notes-bar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin: 0 0 0.75rem; }
.notes-bar__new { display: inline-flex; align-items: center; gap: 6px; }
.notes-bar__filter {
  flex: 1 1 12rem;
  min-width: 0;
  min-height: 36px;
  padding: 6px 10px;
  border: 1px solid var(--color-border);
  background: var(--color-surface);
  color: var(--color-fg);
  font: inherit;
}
.notes-bar__archived[aria-pressed="true"] { background: var(--color-selected); border-color: var(--color-accent); }
.notes-error { margin: 0 0 0.75rem; color: var(--color-danger); overflow-wrap: anywhere; }
.notes-group + .notes-group { margin-top: 1rem; }
.notes-group__head { margin: 0 0 0.5rem; font-size: 0.8125rem; font-weight: 600; text-transform: uppercase; color: var(--color-muted); }
.notes-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.notes-row { min-width: 0; }
.notes-row__open {
  display: flex;
  flex-direction: column;
  gap: 2px;
  padding: 8px 10px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-md);
  color: var(--color-fg);
  text-decoration: none;
  min-width: 0;
}
.notes-row__open--current { border-color: var(--color-accent); }
.notes-row__title { font-weight: 600; overflow-wrap: anywhere; }
.notes-row__text {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  white-space: pre-line;
  overflow-wrap: anywhere;
}
.notes-row__meta { display: flex; flex-wrap: wrap; gap: 4px 10px; font-size: 0.8125rem; min-width: 0; }
@media (max-width: 820px) {
  .notes-bar .btn, .notes-bar__filter { min-height: var(--tap, 44px); }
}
</style>
