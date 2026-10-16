/*
 * CLE-3445 row E1 — editing in place (MessageCard, split out in r13-01).
 *
 * The state machine is utils/msg-edit.mjs and is unit-tested without a
 * browser; everything below is the textarea, the focus and the one await.
 * MessageComposer.vue is the reference for the key handling, NOT a thing to
 * reuse into a row: a row has no attach control, no `/search` mode and no
 * send button. It does share the one @ picker (SPL-985, useMentionPicker).
 *
 * The rule this is shaped by (and now message-edit-v1 §5): nothing
 * on screen is replaced before the hub confirms. So the rendered body stays
 * exactly as it was while the PATCH is in flight, and on a refusal the typed
 * text stays in the still-open box with the reason under it — the human's
 * words are never the thing that gets thrown away.
 *
 * the row under this card can CHANGE, and the edit state must not
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
 * The hosts now key that mount by msg_id, which is the structural fix. The
 * msg_id watcher below is the one that does not depend on every future host
 * remembering: a card whose row identity changed is a card with no edit in
 * progress (useCardReactions clears its own state on the same change).
 *
 * It is a plain reset and NOT closeEdit(): closeEdit() pulls focus back to
 * the row on the next tick, which would steal the caret from wherever the
 * human actually is when a panel re-roots underneath them.
 */
import { computed, nextTick, ref, watch, type Ref } from 'vue'
import { fenceStateAt } from '~/utils/code-blocks.mjs'
import { beginEdit, commitEdit, editFailureKey, editKeyAction, withDraft } from '~/utils/msg-edit.mjs'
import { useMentionPicker } from '~/composables/useMentionPicker'
import { useMentionPoke, type PokeWhere } from '~/composables/useMentionPoke'
import type { useMessageEdit } from '~/composables/useMessageEdit'
import type { SpoolMessage } from '~/types/spool'

type MsgEdit = ReturnType<typeof useMessageEdit>

/* K4: where this message lives - an issue comment, a channel, or a DM between its two ends */
function editWhereOf(m: SpoolMessage): PokeWhere {
  const taskId = String(m.task_id || '')
  const channel = String(m.channel || '')
  /* 'issues' = utils/parent-section.mjs ISSUE_CHANNEL, which must stay out of the initial chunk */
  if (channel === 'issues') return { issue: true, taskId }
  if (channel) return { channel, taskId }
  const to = String(m.to || '')
  if (!to || to === '@channel') return { channel: '', taskId }
  return { ends: [String(m.from || ''), to], taskId }
}

export function useCardEdit(
  props: { msg: SpoolMessage },
  emit: (e: 'edited', msg: SpoolMessage) => void,
  rowEl: Ref<HTMLElement | null>,
  editEl: Ref<HTMLTextAreaElement | null>,
  editError: Ref<string>,
  msgEdit: MsgEdit,
) {
  const { canEdit } = msgEdit
  const edit = ref<ReturnType<typeof beginEdit>>(null)
  const editing = computed(() => edit.value !== null)
  const saving = ref(false)
  const editHintId = useId()
  const draft = computed({
    get: () => edit.value?.draft ?? '',
    set: (v: string) => { edit.value = withDraft(edit.value, v) },
  })
  const editMp = useMentionPicker({
    text: draft,
    el: editEl,
    blocked: () => fenceStateAt(draft.value, editEl.value?.selectionStart ?? draft.value.length).inCode,
  })

  watch(() => String(props.msg?.msg_id || ''), (now, before) => {
    if (now === before) return
    edit.value = null
    saving.value = false
    editError.value = ''
  })

  function startEdit() {
    if (!canEdit(props.msg)) return
    editError.value = ''
    const began = beginEdit(props.msg)
    /* SPL-1009: the box shows mentioned people by name; save() stores their tags */
    edit.value = began && withDraft(began, editMp.decode(began.draft))
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
    nextTick(() => rowEl.value?.focus({ preventScroll: true }))
  }

  const box = { edit, editing, saving, editHintId, draft, editMp, startEdit, closeEdit }
  return { ...box, ...useEditKeys(props, emit, editEl, editError, msgEdit, box) }
}

/** The edit box's keys and its one await: Enter saves, Esc cancels. */
function useEditKeys(
  props: { msg: SpoolMessage },
  emit: (e: 'edited', msg: SpoolMessage) => void,
  editEl: Ref<HTMLTextAreaElement | null>,
  editError: Ref<string>,
  msgEdit: MsgEdit,
  box: { edit: Ref<ReturnType<typeof beginEdit>>, saving: Ref<boolean>, draft: Ref<string>, editMp: ReturnType<typeof useMentionPicker>, closeEdit: () => void },
) {
  const { edit, saving, draft, editMp, closeEdit } = box
  const { commit } = msgEdit
  const { poke } = useMentionPoke()
  const editWhere = (): PokeWhere => editWhereOf(props.msg)

  function onEditKey(ev: KeyboardEvent) {
    if (saving.value) {
      /* in flight: swallow a second Enter so one keystroke cannot send twice */
      if (ev.key === 'Enter' && !ev.shiftKey) ev.preventDefault()
      return
    }
    /* SPL-985: an open @ list owns Enter / Tab / Esc / the arrows */
    if (editMp.onKeydown(ev)) return
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
    const { action, body, error } = commitEdit(withDraft(state, editMp.encode(state.draft)))
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
      /* SPL-985 K3: only a mention the edit ADDED pokes, never one already told */
      void poke({ text: body, before: state.original, where: editWhere() })
      closeEdit()
    } catch (e) {
      saving.value = false
      editError.value = editFailureKey(e)
      nextTick(() => editEl.value?.focus())
    }
  }

  return { onEditKey, save }
}
