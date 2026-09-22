<template>
  <article
    ref="rowEl"
    class="msg"
    :class="{ selected, 'msg--clickable': clickable }"
    tabindex="0"
    :data-msg-id="msg.msg_id || undefined"
    :data-ts="at || undefined"
    :data-task-id="msg.task_id || undefined"
    :data-selected="selected ? 'true' : undefined"
    :aria-current="selected ? 'true' : undefined"
    :aria-posinset="posinset || undefined"
    :aria-setsize="setsize || undefined"
    :aria-label="t('feed.card_aria', { who: (msg.from || t('feed.unknown_author')) + (msg.from_box ? '@' + msg.from_box : ''), kind: kindLabel(String(msg.kind || 'note')) })"
    :aria-describedby="clickable ? 'feed-open-hint' : undefined"
    @click="onClick"
    @keydown="onKey"
  >
    <SpoolAvatar class="avatar" :id="String(msg.from || '')" :box="msg.from_box ? String(msg.from_box) : ''" />
    <div>
      <div class="msg-meta">
        <AgentBadge :id="String(msg.from)" :box="msg.from_box ? String(msg.from_box) : undefined" />
        <KindBadge :kind="String(msg.kind)" />
        <span class="msg-time">{{ time }}</span>
        <span
          v-if="edited"
          class="msg-edited"
          data-test="msg-edited"
          :title="t('feed.edit.marker_title', { at: String(msg.edited_at) })"
        >{{ t('feed.edit.marker') }}</span>
      </div>
      <!--
        CLE-3445: the row BECOMES the box ("the msg becomes once again a
        textbox"), pre-filled with the old body. The rendered body is NOT
        replaced while saving and NOT replaced on failure — the new text
        reaches the screen only when the hub's answer arrives and the row
        itself changes underneath us (message-edit-v1 §5).
      -->
      <textarea
        v-if="editing"
        ref="editEl"
        class="msg-edit-box"
        data-test="msg-edit-box"
        :value="draft"
        :rows="2"
        :disabled="saving"
        :aria-label="t('feed.edit.label')"
        :aria-describedby="editHintId"
        autocomplete="off"
        spellcheck="true"
        @input="draft = ($event.target as HTMLTextAreaElement).value"
        @keydown="onEditKey"
      />
      <MessageBody v-else :body="String(msg.body || '')" />
      <p v-if="editing" :id="editHintId" class="muted msg-edit-hint">
        {{ saving ? t('feed.edit.saving') : t('feed.edit.hint') }}
      </p>
      <p v-if="editError" class="msg-edit-error" role="alert" data-test="msg-edit-error">
        <UiIcon name="alert-triangle" :size="14" />
        <span>{{ t(editError) }}</span>
      </p>
      <FileAttachment
        v-for="(f, i) in files"
        :key="String(f.file_id || f.path || i)"
        :file="f"
      />
      <button
        v-if="threadLink"
        class="icon-btn icon-btn--accent"
        type="button"
        data-test="open-thread"
        :aria-label="t('feed.open_thread')"
        :title="t('feed.open_thread')"
        @click="$emit('open-thread', msg)"
      >
        <UiIcon name="open" :size="16" />
      </button>
      <button
        v-if="count > 0 || alwaysThread"
        class="replies"
        type="button"
        @click="$emit('open-thread', msg)"
      >
        {{ t('feed.replies', { n: count }, count) }}
      </button>
    </div>
  </article>
</template>

<script setup lang="ts">
import { formatThreadTs, formatTs } from '~/utils/channel-feed.mjs'
import { fenceStateAt } from '~/utils/code-blocks.mjs'
import { activityOf } from '~/utils/feed.mjs'
import {
  beginEdit,
  commitEdit,
  editFailureKey,
  editKeyAction,
  isEdited,
  wantsEdit,
  withDraft,
} from '~/utils/msg-edit.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'

import type { FileRef, SpoolMessage } from '~/types/spool'

const props = defineProps<{
  msg: SpoolMessage
  count?: number
  alwaysThread?: boolean
  posinset?: number
  setsize?: number
  threadLink?: boolean
  /** CLE-3427: the whole row opens its thread (pointer and keyboard). */
  clickable?: boolean
  /** the row the open thread is rooted at */
  selected?: boolean
  /** Date.now() at thread open (ticks while open): `yyyy-mm-dd HH:MM:SS sent <age>` */
  sinceMs?: number
  /** CLE-3445: offer the `e` shortcut on this row (author-only; the host decides). */
  editable?: boolean
}>()
const emit = defineEmits<{ 'open-thread': [msg: SpoolMessage], edited: [msg: SpoolMessage] }>()

const { t, te, locale } = useI18n({ useScope: 'global' })
/** v:1 kind in words (feed.kind.*); an unknown kind shows as sent. */
const kindLabel = (k: string) => (te('feed.kind.' + k) ? t('feed.kind.' + k) : k)
/* CLE-3425: a thread card is ordered by its LAST activity, so it shows that
   moment — a card that sits above another must not print an older time. */
const at = computed(() => activityOf(props.msg))
const time = computed(() => (
  props.sinceMs != null
    ? formatThreadTs(at.value, props.sinceMs)
    : formatTs(at.value, locale.value)
))
const files = computed(() => (Array.isArray(props.msg.files) ? props.msg.files : []) as FileRef[])
const count = computed(() => props.count || 0)

/*
 * CLE-3427 — clicking the row opens its thread. The row already carried
 * tabindex="0" for the feed pattern, so the keyboard half is Enter / Space on
 * the focused row; the explicit "open thread" icon button stays as the
 * discoverable, screen-reader-named affordance.
 *
 * Two things a whole-row click must not eat: a click on something that is
 * itself interactive (a link in the body, the copy-code button, a file
 * attachment, the reply-count button — those handle themselves), and the
 * click that ENDS a text selection inside the message, which is how a reader
 * copies a line and never means "open the thread".
 */
const INTERACTIVE = 'a, button, input, textarea, select, label, summary, [role="button"], [contenteditable="true"]'

function selecting() {
  const sel = typeof window !== 'undefined' ? window.getSelection() : null
  return Boolean(sel && !sel.isCollapsed && String(sel).trim())
}

function onClick(ev: MouseEvent) {
  if (!props.clickable) return
  const el = ev.target as HTMLElement | null
  if (el && el.closest && el.closest(INTERACTIVE)) return
  if (selecting()) return
  emit('open-thread', props.msg)
}

function onKey(ev: KeyboardEvent) {
  /* CLE-3445: `e` on the focused row opens the editor. Checked BEFORE the
     open-thread keys so a row that is editable but not clickable still takes
     it, and guarded by the same target === currentTarget rule. */
  if (wantsEdit(ev, { editable: props.editable && !editing.value })) {
    ev.preventDefault()
    startEdit()
    return
  }
  if (!props.clickable) return
  if (ev.key !== 'Enter' && ev.key !== ' ' && ev.key !== 'Spacebar') return
  /* only the row itself: Enter inside a child control is that control's */
  if (ev.target !== ev.currentTarget) return
  ev.preventDefault()
  emit('open-thread', props.msg)
}

/*
 * CLE-3445 row E1 — editing in place.
 *
 * The state machine is utils/msg-edit.mjs and is unit-tested without a
 * browser; everything below is the textarea, the focus and the one await.
 * MessageComposer.vue is the reference for the key handling, NOT a thing to
 * reuse into a row: a row has no attach control, no mention picker, no
 * `/search` mode and no send button.
 *
 * The rule this is shaped by (CLE-3433, and now message-edit-v1 §5): nothing
 * on screen is replaced before the hub confirms. So the rendered body stays
 * exactly as it was while the PATCH is in flight, and on a refusal the typed
 * text stays in the still-open box with the reason under it — the human's
 * words are never the thing that gets thrown away.
 */
const edit = ref<ReturnType<typeof beginEdit>>(null)
const editing = computed(() => edit.value !== null)
const saving = ref(false)
const editError = ref('')
const editEl = ref<HTMLTextAreaElement | null>(null)
const rowEl = ref<HTMLElement | null>(null)
const editHintId = useId()
const edited = computed(() => isEdited(props.msg))
const { canEdit, commit } = useMessageEdit()

const draft = computed({
  get: () => edit.value?.draft ?? '',
  set: (v: string) => { edit.value = withDraft(edit.value, v) },
})

/*
 * CLE-3446 — the row under this card can CHANGE, and the edit state must not
 * ride across when it does.
 *
 * THE OWNER, 2026-09-22: "the editing of the msg appears whenever the bot is
 * sending". The 3rd panel's pinned root is one MessageCard that is re-rooted
 * rather than remounted (stores/live.ts open() reassigns taskId without it
 * ever passing through null, so the <aside> is never torn down). `editable`
 * is a prop and re-evaluated correctly; `edit` / `saving` / `editError` are
 * local refs and were not. So an editor opened on your own message stayed
 * open on whatever landed in the panel next -- measured in Chrome with the
 * textarea sitting on CLE-07@box-a's message still holding HUM-1's body
 * (tests/e2e/msg-edit.test.mjs step 8.1).
 *
 * The hosts now key that mount by msg_id, which is the structural fix. This
 * watcher is the one that does not depend on every future host remembering:
 * a card whose row identity changed is a card with no edit in progress.
 *
 * It is a plain reset and NOT closeEdit(): closeEdit() pulls focus back to
 * the row on the next tick, which would steal the caret from wherever the
 * human actually is when a panel re-roots underneath them.
 */
watch(() => String(props.msg?.msg_id || ''), (now, before) => {
  if (now === before) return
  edit.value = null
  saving.value = false
  editError.value = ''
})

function startEdit() {
  if (!canEdit(props.msg)) return
  editError.value = ''
  edit.value = beginEdit(props.msg)
  if (!edit.value) return
  nextTick(() => {
    const el = editEl.value
    if (!el) return
    el.focus()
    /* caret at the END of the old text: the human is amending, not retyping */
    el.setSelectionRange(el.value.length, el.value.length)
  })
}

/** Close the editor and hand the keyboard back to the row it came from. */
function closeEdit() {
  edit.value = null
  saving.value = false
  /* the textarea is gone by the next tick (v-if), so focus goes to the row —
     otherwise the focus falls to <body> and the next key press does nothing */
  nextTick(() => rowEl.value?.focus())
}

function onEditKey(ev: KeyboardEvent) {
  if (saving.value) {
    /* in flight: swallow a second Enter so one keystroke cannot send twice */
    if (ev.key === 'Enter' && !ev.shiftKey) ev.preventDefault()
    return
  }
  const inCode = fenceStateAt(draft.value, editEl.value?.selectionStart ?? draft.value.length).inCode
  const act = editKeyAction(ev, { inCode })
  if (act === 'cancel') {
    ev.preventDefault()
    ev.stopPropagation()
    editError.value = ''
    closeEdit()
    return
  }
  if (act !== 'commit') return
  ev.preventDefault()
  void save()
}

async function save() {
  const state = edit.value
  if (!state) return
  const { action, body, error } = commitEdit(state)
  if (action === 'unchanged') {
    editError.value = ''
    closeEdit()
    return
  }
  if (action === 'empty') {
    /* an emptied box is a delete, and nobody has asked for one: the editor
       stays open holding what was typed */
    editError.value = editFailureKey(error)
    return
  }
  saving.value = true
  editError.value = ''
  try {
    const row = await commit(state.msgId, body)
    /* the hub has answered: only NOW may the screen change, and the host owns
       the rows, so it is told rather than reaching into props.msg */
    emit('edited', row)
    closeEdit()
  } catch (e) {
    saving.value = false
    editError.value = editFailureKey(e)
    nextTick(() => editEl.value?.focus())
  }
}
</script>
