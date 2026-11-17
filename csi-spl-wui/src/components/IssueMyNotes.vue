<!-- Spec 155 2.12 (SPL-5769, HUM-24 topic bc7c22e1: a note written for a task
     "does not show in the task's file"). The person's own notes that link the
     open issue, under its comment box. A note is the person's alone (2.2):
     each person sees their own notes here, nobody else's, and the hub reads
     only the session's person. Archived notes are left out; with none, or
     with Notes off, the list shows nothing. Each row opens its note. Its own
     chunk (LazyIssueMyNotes): the initial JS does not grow. -->
<template>
  <section v-if="rows.length" class="issue-my-notes" data-test="issue-my-notes" :aria-label="t('issue_my_notes.title')">
    <h3 class="issue-my-notes__h">{{ t('issue_my_notes.title') }}</h3>
    <ul class="issue-my-notes__list">
      <li v-for="n in rows" :key="n.id" class="issue-my-notes__row" data-test="issue-my-note" :data-note-id="n.id">
        <UiIcon name="notes" :size="14" class="issue-my-notes__icon" />
        <NuxtLink class="issue-my-notes__link" data-test="issue-my-note-link" :to="localePath('/notes?note=' + encodeURIComponent(n.id))">{{ titleOf(n) }}</NuxtLink>
      </li>
    </ul>
  </section>
</template>

<script setup lang="ts">
import type { NoteOnIssue } from '~/stores/notes'
import { useNotesStore } from '~/stores/notes'
import { useAddToNote } from '~/composables/useAddToNote'

const props = defineProps<{
  /** the open issue's key, SPL-12 */
  issueKey: string
}>()

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const note = useAddToNote()
const store = useNotesStore()
const rows = ref<NoteOnIssue[]>([])

/* a note with no title shows the first line of its text, as the notes list
   does; the hub sends no body here, so the line comes from the list the
   notes store already holds */
function titleOf(n: NoteOnIssue): string {
  const row = store.notes.find((x) => x.id === n.id)
  return n.title || String(row?.snippet || '').split('\n').find((l) => l.trim())?.trim() || t('notes.untitled')
}

let seq = 0
async function load() {
  const key = props.issueKey
  const ws = note.workspace()
  const mine = ++seq
  if (!key || !ws || !note.offered.value) {
    rows.value = []
    return
  }
  try {
    const got = await store.onIssue(ws, key)
    if (mine === seq) rows.value = got.filter((n) => !n.archived)
  } catch {
    /* notes off (404 notes_off) or a failed read: nothing to list */
    if (mine === seq) rows.value = []
  }
}
/* read again when the issue changes, and when the person's notes do: an Add
   to note from this dialog adds a link and the store's list follows it */
watch(() => [props.issueKey, store.notes, note.offered.value], load, { immediate: true })
</script>

<style scoped>
.issue-my-notes {
  display: flex;
  flex-direction: column;
  gap: 6px;
  margin: 8px 0;
  padding: 8px 0;
  border-top: 1px solid var(--color-border);
}
.issue-my-notes__h {
  margin: 0;
  font-size: 0.8rem;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  color: var(--color-muted);
}
.issue-my-notes__list {
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.issue-my-notes__row {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}
.issue-my-notes__icon {
  flex: none;
  color: var(--color-muted);
}
.issue-my-notes__link {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
