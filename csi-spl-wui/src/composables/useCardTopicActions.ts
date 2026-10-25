/*
 * What MessageCard's menu does to a topic or a message (r13-01): archive,
 * delete, merge, make an issue, make a task. The card decides what the menu
 * offers; these are the handlers, and the hub re-checks every one.
 */
import { ref, type Ref } from 'vue'
import { editFailureKey } from '~/utils/msg-edit.mjs'
import { openingCardId, topicErrorKey } from '~/utils/topic-archive.mjs'
import { paneOfRow } from '~/utils/reselect-row.mjs'
import { useArchiveUndo } from '~/composables/useArchiveUndo'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { noteError } from '~/composables/errorJournal.mjs'
import type { useMessageEdit } from '~/composables/useMessageEdit'
import type { CardMenu } from '~/composables/useCardReactions'
import type { SpoolMessage } from '~/types/spool'

type CardEmit = ((e: 'deleted', msg: SpoolMessage) => void) & ((e: 'edited', msg: SpoolMessage) => void)
type MsgEdit = ReturnType<typeof useMessageEdit>

/** A removal in flight, and the reason the last one was refused. */
export interface CardBusy { removing: Ref<boolean>, editError: Ref<string> }

/* SPL topic-archive: the hub acts only on a topic's OPENING card (spec 041 §2);
   a later is_parent 1 line (an agent's, in a topic whose opener is gone) is
   refused 409 not_a_card. This card menu shows on every is_parent 1 line, so
   resolve the task's opening card first and act on THAT - clicking any card of
   a topic then archives / deletes the topic. Falls back to this card. */
async function topicOpenerId(props: { msg: SpoolMessage, paneOpener?: SpoolMessage | null }, api: ReturnType<typeof useSpoolApi>): Promise<string> {
  /* HUM-10: a topic pane knows its opener; the latest reply archives it */
  if (props.paneOpener?.msg_id) return String(props.paneOpener.msg_id)
  const own = String(props.msg.msg_id || '')
  const task = String(props.msg.task_id || '')
  if (!task) return own
  try {
    const page = await api.getTopic(task, { limit: 30 })
    return openingCardId(page?.messages, own)
  } catch {
    return own
  }
}

export function useCardTopicActions(
  props: { msg: SpoolMessage, paneOpener?: SpoolMessage | null },
  emit: CardEmit,
  rowEl: Ref<HTMLElement | null>,
  busy: CardBusy,
  menu: CardMenu,
  msgEdit: MsgEdit,
) {
  const { removing, editError } = busy
  const { dropEverywhere } = msgEdit
  const { close: closeMenu } = menu
  const api = useSpoolApi()
  const archiveUndo = useArchiveUndo()
  const topicDeleteOpen = ref(false)
  // The opening card the delete dialog acts on: resolved from the clicked card's
  // task (topicOpenerId) so a non-opener card still deletes the topic.
  const topicDeleteMsgId = ref('')
  const msgDeleteOpen = ref(false)

  /** SPL-983: archive the topic. The card leaves every feed here at once; the
      hub's topic_archived frame tells the other tabs. True when it archived. */
  async function onMenuArchive(): Promise<boolean> {
    closeMenu()
    if (removing.value) return false
    removing.value = true
    editError.value = ''
    try {
      const id = await topicOpenerId(props, api)
      if (!id) return false
      await api.archiveTopic(id, true)
      dropEverywhere(id)
      emit('deleted', props.msg)
      /* SPL-1264: offer Undo (the same endpoint, archived=false) for 0.7 s;
         CLE-77871: and from which pane, so Undo selects it there again */
      archiveUndo.offerUndo(id, paneOfRow(rowEl.value))
      return true
    } catch (e) {
      editError.value = topicErrorKey(e, 'archive')
      return false
    } finally {
      removing.value = false
    }
  }

  async function onMenuDeleteTopic() {
    closeMenu()
    topicDeleteMsgId.value = await topicOpenerId(props, api)
    topicDeleteOpen.value = true
  }

  function onTopicDeleted(out: { msg_ids: string[] }) {
    for (const id of out.msg_ids) dropEverywhere(id)
    emit('deleted', props.msg)
  }

  /* SPL-1001: the menu's Delete confirms first (Delete / Backspace on a
     focused thread row is the keyboard shortcut and stays immediate). */
  function onMenuDelete() {
    closeMenu()
    msgDeleteOpen.value = true
  }

  return { topicDeleteOpen, topicDeleteMsgId, msgDeleteOpen, onMenuArchive, onMenuDeleteTopic, onTopicDeleted, onMenuDelete }
}

export function useCardMessageActions(
  props: { msg: SpoolMessage, mergePrev?: SpoolMessage | null, mergeNext?: SpoolMessage | null },
  emit: CardEmit,
  busy: CardBusy,
  editing: Ref<boolean>,
  menu: CardMenu,
  msgEdit: MsgEdit,
) {
  const { removing, editError } = busy
  const { canEdit, removeMessage, mergeInto } = msgEdit
  const { close: closeMenu } = menu
  const parentDeps = { api: useSpoolApi(), router: useRouter() }
  const localePath = useLocalePath()
  /* t1 b6c742f0 (HUM-10): MessageMenu runs a person's message's AI actions;
     a failure is shown here, under the card */
  const aiError = ref('')
  function onAiFail(key: string) {
    aiError.value = key
  }

  /**
   * Fold this message into the neighbor. The neighbor keeps both bodies, older
   * first, and this row is deleted. CLE-35064: that is ONE hub request and one
   * transaction (POST /v1/messages/{id}/merge). It used to be an edit and then
   * a delete, and on prd the delete never went out, so the source stayed. A
   * refusal leaves both rows as they were.
   */
  async function onMerge(which: 'previous' | 'next') {
    const other = which === 'previous' ? props.mergePrev : props.mergeNext
    if (!other || removing.value || editing.value) return
    if (!canEdit(props.msg) || !canEdit(other)) return
    const keepId = String(other.msg_id || '')
    const dropId = String(props.msg.msg_id || '')
    if (!keepId || !dropId || keepId === dropId) return
    closeMenu()
    removing.value = true
    editError.value = ''
    try {
      const row = await mergeInto(dropId, keepId)
      emit('edited', row)
      emit('deleted', props.msg)
    } catch (e) {
      removing.value = false
      editError.value = editFailureKey(e)
    }
  }

  async function remove() {
    if (removing.value || editing.value) return
    if (!canEdit(props.msg)) return
    const id = String(props.msg.msg_id || '')
    if (!id) return
    removing.value = true
    editError.value = ''
    try {
      await removeMessage(id)
      emit('deleted', props.msg)
    } catch (e) {
      removing.value = false
      editError.value = editFailureKey(e)
    }
  }

  /* t1 5ea2e615 (owner db5ed497): "An owner question should not become an
     issue until the owner decides that." A workspace owner makes an issue of a
     message that carries the blocker mark; the hub re-checks both, and the new
     (or already made) issue opens on the issues sheet. */
  async function onMakeIssue() {
    closeMenu()
    aiError.value = ''
    try {
      const out = await parentDeps.api.makeBlockerIssue(String(props.msg.msg_id || ''))
      await parentDeps.router.push(localePath({ path: '/issues', query: { issue: out.issue.key } }))
    } catch {
      aiError.value = 'feed.msg_menu.make_issue_failed'
    }
  }

  return { aiError, onAiFail, onMerge, remove, onMakeIssue }
}

/* SPL-3344 (HUM-10 t1 2a9e18c7, msg 3e7fc3b7: "converting a blocker msg
   to a task ... I am doing this quite often"): Make it a task is Kind ->
   Task in one step - the same hub call and the same store update as
   KindBadge's pick. The menu offers it only on a blocker the viewer may
   re-type; the hub re-checks. */
export function useCardMakeTask(props: { msg: SpoolMessage }, menu: CardMenu, msgEdit: MsgEdit, aiError: Ref<string>) {
  const api = useSpoolApi()
  const { t } = useI18n({ useScope: 'global' })
  async function onMakeTask() {
    menu.close()
    const id = String(props.msg.msg_id || '')
    const from = String(props.msg.kind || '')
    if (!id || from !== 'blocker') return
    aiError.value = ''
    try {
      const row = await api.setMessageKind(id, 'task')
      msgEdit.applyKind(from, row, props.msg)
    } catch (err) {
      aiError.value = 'feed.kind_set.failed'
      noteError({ source: 'kind-set', message: t('feed.kind_set.failed'), code: (err as { token?: string })?.token, error: err })
    }
  }
  return { onMakeTask }
}
