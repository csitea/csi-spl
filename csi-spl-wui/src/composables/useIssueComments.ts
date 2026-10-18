import type { ComputedRef, Ref } from 'vue'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { applyEdit } from '~/utils/msg-edit.mjs'
import { applyReactions as patchReactions } from '~/utils/emoji.mjs'
import { withoutMsg } from '~/utils/feed.mjs'
import { descFileLink, uploadRefs, type IssueFileRef } from '~/utils/issue-files.mjs'
import { uploadWithFreshToken } from '~/utils/upload-retry.mjs'
import { ISSUE_CHANNEL } from '~/utils/parent-section.mjs'
import type { Issue } from '~/utils/issues.mjs'
import type { ReactionUpdate, SpoolMessage } from '~/types/spool'
import { useMentionPicker } from '~/composables/useMentionPicker'
import { useMentionPoke } from '~/composables/useMentionPoke'
import { useFileAttach } from '~/composables/useFileAttach'
import { onDeleteRestore } from '~/composables/useDeleteUndo'
import { useOmniboxStore } from '~/stores/omnibox'
import type { IssuesApi, IssuesLive } from '~/composables/issuesPageTypes'

/**
 * The open issue's discussion: its comments (live), the comment box, the
 * phone dock's GO and a description's attached files. Moved out of
 * pages/issues.vue (r13-06).
 */
/* an issue comment is the whole message row (MessageCard reads kind, to,
   reactions, edited_at ...), with the fields the page reads made safe */
type Note = SpoolMessage
export type IssueCommentsOpts = {
  api: IssuesApi
  live: IssuesLive
  t: (key: string, named?: Record<string, unknown>) => string
  detail: Ref<Issue | null>
  creating: Ref<boolean>
  phone: ComputedRef<boolean>
  busy: Ref<boolean>
  saveError: Ref<string>
  failKey: (e: unknown) => string
  commentEl: Ref<HTMLTextAreaElement | null>
  commentFileEl: Ref<HTMLInputElement | null>
}

function asNotes(rows: unknown): Note[] {
  if (!Array.isArray(rows)) return []
  const out: Note[] = []
  for (const raw of rows) {
    if (!raw || typeof raw !== 'object') continue
    const m = raw as Record<string, unknown>
    const id = String(m.msg_id || '')
    if (!id) continue
    out.push({
      ...(m as unknown as SpoolMessage),
      msg_id: id,
      from: String(m.from || ''),
      from_box: String(m.from_box || ''),
      body: String(m.body || ''),
      ts: String(m.ts || m.received_at || ''),
    })
  }
  return out
}

export function useIssueComments(o: IssueCommentsOpts) {
  const comments = ref<Note[]>([])
  /* SPL-985 (spec 042 §3): whoever a stored description, comment or new issue
     newly mentions gets a DM asking them to act; issues are tenant-wide (K4) */
  const { poke } = useMentionPoke()
  const rows = useCommentRows(o, comments)
  const post = useCommentPost(o, { comments, poke })
  const box = useCommentBox(o, post)
  useDockComment(o, post)
  watch(o.creating, (on) => { if (on) comments.value = [] })
  return { comments, poke, ...rows, ...post, ...box }
}

/* the page's own copy of the comments; the card already told the stores */
function useCommentRows(o: IssueCommentsOpts, comments: Ref<Note[]>) {
  function onCommentEdited(row: SpoolMessage) {
    comments.value = applyEdit(comments.value, row) as Note[]
  }
  /* CLE-77840: a comment deleted with the Delete key comes back on Undo
     (useDeleteUndo); it goes back where it was. */
  const commentDeletedAt = new Map<string, number>()
  function onCommentDeleted(row: { msg_id?: string }) {
    const id = String(row?.msg_id || '')
    const at = comments.value.findIndex((c) => c.msg_id === id)
    if (at >= 0) commentDeletedAt.set(id, at)
    comments.value = withoutMsg(comments.value, id) as Note[]
  }
  const offCommentRestore = onDeleteRestore((row) => {
    const id = String(row.msg_id || '')
    const at = commentDeletedAt.get(id)
    if (at === undefined) return
    commentDeletedAt.delete(id)
    if (comments.value.some((c) => c.msg_id === id)) return
    const next = comments.value.slice()
    next.splice(Math.min(at, next.length), 0, row as Note)
    comments.value = next
  })
  function onCommentReacted(update: ReactionUpdate) {
    comments.value = patchReactions(comments.value, update) as Note[]
  }
  const offs: (() => void)[] = [offCommentRestore]
  onMounted(() => {
    offs.push(o.live.onMessage((m) => {
      const issue = o.detail.value
      if (!issue || String(m.task_id || '') !== issue.task_id) return
      const note = asNotes([m])[0]
      if (note && !comments.value.some((c) => c.msg_id === note.msg_id)) comments.value = [...comments.value, note]
    }))
    offs.push(o.live.onEdited((m) => onCommentEdited(m as unknown as SpoolMessage)))
    offs.push(o.live.onDeleted((m) => onCommentDeleted(m as { msg_id?: string })))
    offs.push(o.live.onReaction((m) => onCommentReacted(m as unknown as ReactionUpdate)))
  })
  onUnmounted(() => { for (const off of offs) off() })
  return { onCommentEdited, onCommentDeleted, onCommentReacted }
}

type CommentPostDeps = { comments: Ref<Note[]>, poke: ReturnType<typeof useMentionPoke>['poke'] }

function useCommentPost(o: IssueCommentsOpts, d: CommentPostDeps) {
  let followed = ''
  async function loadComments(issue: Issue | null) {
    d.comments.value = []
    const sock = o.live.ensure()
    if (followed && sock) sock.unsubscribe(followed)
    followed = ''
    if (!issue || !issue.task_id) return
    followed = issue.task_id
    if (sock) sock.subscribe(issue.task_id)
    try {
      const data = await withSessionRetry(o.api, () => o.api.getTopic(issue.task_id, { limit: 50 }))
      d.comments.value = asNotes(data && data.messages)
    } catch {
      d.comments.value = []
    }
  }
  onUnmounted(() => {
    const sock = o.live.ensure()
    if (followed && sock) sock.unsubscribe(followed)
  })
  /* the post itself - a comment, or an AI action picked on the issue's menu */
  async function sendToDiscussion(issue: Issue, text: string, files: IssueFileRef[] = []) {
    const sock = o.live.ensure()
    if (sock) {
      await sock.send({ task_id: issue.task_id, kind: 'note', body: text, files, channel: issue.channel || ISSUE_CHANNEL, is_parent: 0 })
    } else {
      await o.api.sendMessage({ text, task_id: issue.task_id, channel: issue.channel || ISSUE_CHANNEL, is_parent: 0, files })
    }
    if (text) void d.poke({ text, where: { issue: true, issueKey: issue.key } })
  }
  /* one comment into the issue's discussion (is_parent 0 on its task) - the
     discussion box and, on a phone, the bottom dock's GO */
  async function postComment(issue: Issue, text: string, files: IssueFileRef[] = []) {
    await sendToDiscussion(issue, text, files)
    await loadComments(issue)
  }
  /* each picked file up to the hub (POST /v1/files), as the composer's send does */
  const uploadFiles = (files: File[]) => uploadRefs(files, (f) => uploadWithFreshToken(o.api, o.live, f))
  /* HUM-10 (t1 43ebdf0b): a description's file. The hub serves a file only to a
     reader of a message that carries it (rdb 0028), so the file rides on a note
     in the issue's discussion and the description names it with a link to it
     (utils/issue-files.mjs). */
  async function attachToDescription(files: File[]): Promise<string[]> {
    const issue = o.detail.value
    if (!issue || !issue.task_id) throw new Error('issue has no discussion')
    const refs = await uploadFiles(files)
    await sendToDiscussion(issue, '', refs)
    void loadComments(issue)
    return refs.map((r) => descFileLink(r, o.api.fileUrl(r.file_id)))
  }
  return { loadComments, sendToDiscussion, postComment, uploadFiles, attachToDescription }
}

type CommentPost = ReturnType<typeof useCommentPost>

function useCommentBox(o: IssueCommentsOpts, p: CommentPost) {
  const commentText = ref('')
  const commentMp = useMentionPicker({ text: commentText, el: o.commentEl })
  const commentFiles = useFileAttach(o.commentFileEl)
  const { picked: commentPicked, pickLost: commentPickLost } = commentFiles
  async function sendComment() {
    const issue = o.detail.value
    const text = commentMp.encode(commentText.value).trim()
    const picked = commentPicked.value.slice()
    if (!issue || !issue.task_id || (!text && !picked.length)) return
    o.busy.value = true
    o.saveError.value = ''
    try {
      await p.postComment(issue, text, await p.uploadFiles(picked))
      commentText.value = ''
      commentPicked.value = []
    } catch (e) {
      o.saveError.value = o.failKey(e)
    } finally {
      o.busy.value = false
    }
  }
  /* owner, prd t1 topic 110d842c: a comment saves when the box loses focus (a
     click elsewhere), like the issue description autosaves - not only on Enter.
     MentionList swallows its own mousedown, so picking a name keeps the focus
     and never blur-posts a half-typed @token. */
  function onCommentBlur() {
    if (o.busy.value) return
    /* the attach dialog's focus loss is not a click elsewhere */
    if (commentFiles.picking()) return
    if (!commentMp.encode(commentText.value).trim() && !commentPicked.value.length) return
    void sendComment()
  }
  return { commentText, commentMp, commentFiles, commentPicked, commentPickLost, sendComment, onCommentBlur }
}

/* (owner, prd t1 topic 110d842c: "In issues on mobile, clicking on
   the omnibox, typing and clicking the GO button does not create a
   comment"). /issues registered no omnibox send target, so the phone dock's
   GO had nowhere to send and did nothing. With an issue open on a phone
   (level 3) the dock now comments on it; the list stays search-only.
   Desktop keeps its Omnibox as search - the discussion box is on screen. */
function useDockComment(o: IssueCommentsOpts, p: CommentPost) {
  const omniboxStore = useOmniboxStore()
  const commentOwner = Symbol('issue-comment')
  async function sendDockComment(text: string, files: File[]) {
    const issue = o.detail.value
    if (!issue || !issue.task_id) return
    /* a comment carries no attachment (the discussion box has none): refuse
       rather than post the text and drop the file on the floor */
    if (files.length) throw Object.assign(new Error('issue comments take no files'), { token: 'files' })
    const body = text.trim()
    if (!body) return
    o.busy.value = true
    try {
      await p.postComment(issue, body)
    } finally {
      o.busy.value = false
    }
    /* the discussion is below the fold on a phone: without this the only sign
       of the post was an empty dock - the owner's "does not create a comment"
       again. Comments are oldest first, so the new one is the last card. */
    await nextTick()
    const cards = document.querySelectorAll('[data-test=issues-comment]')
    cards[cards.length - 1]?.scrollIntoView({ block: 'center' })
  }
  const dockComment = computed(() => Boolean(o.phone.value && o.detail.value && o.detail.value.task_id && !o.creating.value))
  watch(dockComment, (on) => {
    if (!on) { omniboxStore.unregister(commentOwner); return }
    omniboxStore.register({
      owner: commentOwner,
      placeholder: () => o.t('composer.target_comment', { target: o.detail.value?.key || '' }),
      dock: () => ({ reply: true, target: o.detail.value?.key || '', comment: true }),
      send: sendDockComment,
      busy: () => o.busy.value,
    })
  }, { immediate: import.meta.client })
  onBeforeUnmount(() => omniboxStore.unregister(commentOwner))
}
