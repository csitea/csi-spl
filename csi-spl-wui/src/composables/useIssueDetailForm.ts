import type { ComputedRef, Ref } from 'vue'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { ISSUE_STATUSES, PRIO_DEFAULT, isTopKind, normalizeIssue, type EpicSummary, type Issue } from '~/utils/issues.mjs'
import { deadlineToLocalInput, localInputToDeadline } from '~/utils/issues-view.mjs'
import { deadlineOverdue, issueCalendarHref } from '~/utils/issue-calendar-link.mjs'
import type { IssueSave, IssuesApi } from '~/composables/issuesPageTypes'
import type { IssueDraft } from '~/composables/useIssuePicker'

/**
 * The issue form's inputs: the new-issue draft, the open issue's title,
 * description, kind, priority, labels and deadline as the form shows them,
 * the writes each one makes, and the open issue's subtasks. Moved out of
 * pages/issues.vue (r15-01); the page owns `detail`, `creating` and the save.
 */
type Poke = (p: { text: string, before?: string, where: { issue: boolean, issueKey: string } }) => unknown
export type IssueDetailFormOpts = {
  api: IssuesApi
  phone: ComputedRef<boolean>
  detail: Ref<Issue | null>
  creating: Ref<boolean>
  busy: Ref<boolean>
  saveError: Ref<string>
  saveReason: Ref<string>
  epics: Ref<EpicSummary[]>
  epicF: ComputedRef<string>
  defaultDiscussion: Ref<string>
  failKey: (e: unknown) => string
  save: IssueSave
  hold: (issue: Issue) => void
  poke: Poke
  /* a created issue: the sheet's row (> 820 px) or the phone's open issue */
  created: (issue: Issue) => void
  openIssueKey: (key: string) => Promise<unknown>
}

function newDraft(): IssueDraft {
  return {
    title: '', description: '', status: 'todo', priority: PRIO_DEFAULT,
    assignee: '', labels: [], deadlineLocal: '',
    epic: '', kind: 'issue',
    /* SPL-1593: the discussions the new issue links (topic ids, short ids) */
    discussions: [],
  }
}

/* what the form shows: the draft while creating, else the open issue */
function useFormView(o: IssueDetailFormOpts, draft: IssueDraft) {
  const { creating, detail } = o
  const activeAssignee = computed(() => creating.value ? draft.assignee : (detail.value?.assignee || ''))
  const activeLabels = computed(() => creating.value ? draft.labels : (detail.value?.labels || []))
  const form = computed(() => {
    if (creating.value) {
      return {
        key: '', title: draft.title, description: draft.description, status: draft.status,
        priority: draft.priority, level: isTopKind(draft.kind) ? 1 : 2, deadline: draft.deadlineLocal,
        created_by: '', updated_by: '', task_id: '', epic: isTopKind(draft.kind) ? '' : draft.epic, kind: draft.kind as string,
      }
    }
    const d = detail.value
    if (!d) return null
    return {
      key: d.key, title: d.title, description: d.description, status: d.status,
      priority: d.priority, level: d.level, deadline: deadlineToLocalInput(d.deadline),
      created_by: d.created_by, updated_by: d.updated_by, task_id: d.task_id, epic: d.epic, kind: d.kind as string,
    }
  })
  /* SPL-1593: a subtask links the discussions of the issue it is under */
  const parentDiscussions = computed(() => (detail.value?.discussions || []).map((d) => d.task_id))
  /* SPL-2034: the open issue's calendar link (a set deadline only) and its
     overdue tint */
  const detailCalendarHref = computed(() => (!creating.value && detail.value ? issueCalendarHref(detail.value.key, detail.value.deadline) : ''))
  const detailOverdue = computed(() => Boolean(detailCalendarHref.value) && deadlineOverdue(detail.value?.deadline || ''))
  function detailOrDraft(): Issue {
    if (detail.value && !creating.value) return detail.value
    return normalizeIssue({
      key: draft.title ? 'draft' : '', title: draft.title, description: draft.description,
      status: draft.status, priority: draft.priority, level: isTopKind(draft.kind) ? 1 : 2,
      assignee: draft.assignee, labels: draft.labels, epic: draft.epic, kind: draft.kind,
    })
  }
  return { activeAssignee, activeLabels, form, parentDiscussions, detailCalendarHref, detailOverdue, detailOrDraft }
}

/* the title and description inputs */
function useTextInputs(o: IssueDetailFormOpts, draft: IssueDraft, createIssue: () => Promise<void>) {
  const { creating, detail } = o
  /* the open issue's title as typed, until it is saved. Vue writes `value` on
     every re-render, so with form.title alone a re-render while typing (the
     comments, subtasks or opened mark loading as the modal opens) put the old
     title back under the cursor: "Beta row" + "al" (spec 133 round 19) */
  const detailTitleEdit = ref<string | null>(null)
  watch(() => detail.value?.key, () => { detailTitleEdit.value = null })
  function onDraftInput(ev: Event, field: 'title') {
    const value = (ev.target as HTMLInputElement).value
    if (creating.value) draft[field] = value
    else detailTitleEdit.value = value
  }
  async function onTitle(ev: Event) {
    const value = (ev.target as HTMLInputElement).value
    if (creating.value) { draft.title = value; return }
    if (!detail.value || value === detail.value.title) { detailTitleEdit.value = null; return }
    await o.save(detail.value.key, { title: value })
    /* keys typed while the save was out stay */
    if (detailTitleEdit.value === value) detailTitleEdit.value = null
  }
  /* the submit key in the description: a new issue is created, an existing
     one's text is already saved by IssueDescription */
  function onDescriptionSubmit() {
    if (creating.value && !o.busy.value && draft.title.trim()) void createIssue()
  }
  function onDescriptionDraft(value: string) {
    if (creating.value) draft.description = value
  }
  /* IssueDescription's save: true when stored, so a failure keeps its editor */
  async function saveDescription(value: string) {
    if (creating.value) { draft.description = value; return true }
    if (!detail.value) return false
    if (value === detail.value.description) return true
    const key = detail.value.key
    const before = detail.value.description
    await o.save(key, { description: value })
    if (!o.saveError.value) void o.poke({ text: value, before, where: { issue: true, issueKey: key } })
    return !o.saveError.value
  }
  return { detailTitleEdit, onDraftInput, onTitle, onDescriptionSubmit, onDescriptionDraft, saveDescription }
}

/* the kind, priority, labels and deadline inputs */
function useFieldInputs(o: IssueDetailFormOpts, draft: IssueDraft, activeLabels: ComputedRef<string[]>) {
  const { creating, detail, save } = o
  function toggleKind() {
    draft.kind = draft.kind === 'issue' ? 'epic' : draft.kind === 'epic' ? 'feature' : 'issue'
  }
  /* CLE-77816: a level-1 row (epic / feature) toggles between the two while it is
     open in the dialog; both are level 1, so the tree is untouched. Kind is not
     editable to `issue` here (that would move it in the tree - level does that). */
  function editKind() {
    const d = detail.value
    if (!d || !isTopKind(d.kind)) return
    void save(d.key, { kind: d.kind === 'epic' ? 'feature' : 'epic' })
  }
  function onDetailPriority(ev: Event) {
    const n = Number((ev.target as HTMLSelectElement).value)
    if (creating.value) { draft.priority = n; return }
    if (detail.value && n && n !== detail.value.priority) void save(detail.value.key, { priority: n })
  }
  function applyDeadline(local: string) {
    if (creating.value) { draft.deadlineLocal = local; return }
    if (!detail.value) return
    const deadline = localInputToDeadline(local)
    if (deadline === null) return
    void save(detail.value.key, { deadline })
  }
  /* SPL-1633: the x on a chip of the issue modal's Labels field */
  async function removeLabel(id: string) {
    if (creating.value) { draft.labels = draft.labels.filter((x) => x !== id); return }
    const issue = detail.value
    if (!issue?.key || !issue.labels.includes(id)) return
    await save(issue.key, { labels: issue.labels.filter((x) => x !== id) })
  }
  function removeLastLabel() {
    const last = activeLabels.value[activeLabels.value.length - 1]
    if (last) void removeLabel(last)
  }
  return { toggleKind, editKind, onDetailPriority, applyDeadline, removeLabel, removeLastLabel }
}

/* the body the hub creates the draft from */
function createBody(draft: IssueDraft, title: string): Record<string, unknown> {
  const body: Record<string, unknown> = {
    title,
    description: draft.description,
    status: draft.status,
    priority: draft.priority,
  }
  body.discussions = draft.discussions.slice()
  if (draft.assignee) body.assignee = draft.assignee
  if (draft.labels.length) body.labels = draft.labels.slice()
  /* The label and parent forms work on every hub since 0.7.0 (issues-v1 §8:
     the epic label makes an epic, parent is the epic). */
  if (isTopKind(draft.kind)) body.kind = draft.kind
  else if (draft.epic) body.parent = draft.epic /* W16: no epic = a lone level-2 issue */
  const deadline = localInputToDeadline(draft.deadlineLocal)
  if (deadline) body.deadline = deadline
  return body
}

function useCreate(o: IssueDetailFormOpts, draft: IssueDraft) {
  const { busy, saveError } = o
  async function createIssue() {
    const title = draft.title.trim()
    if (!title || busy.value) return
    /* SPL-1593: the hub refuses an issue that links no discussion */
    if (!draft.discussions.length) {
      o.saveReason.value = ''
      saveError.value = 'issue_discussions.required'
      return
    }
    busy.value = true
    saveError.value = ''
    const body = createBody(draft, title)
    try {
      const data = await withSessionRetry(o.api, () => o.api.createIssue(body))
      const created = normalizeIssue(data.issue)
      o.hold(created)
      void o.poke({ text: `${title}\n${String(body.description || '')}`, where: { issue: true, issueKey: created.key } })
      o.creating.value = false
      o.created(created)
    } catch (e) {
      saveError.value = o.failKey(e)
    } finally {
      busy.value = false
    }
  }
  /* a fresh draft for a new issue, in `status` when it is one */
  function resetDraft(status = '') {
    Object.assign(draft, newDraft())
    draft.status = (ISSUE_STATUSES as readonly string[]).includes(status) ? status : 'todo'
    draft.discussions = o.defaultDiscussion.value ? [o.defaultDiscussion.value] : []
    const epics = o.epics.value
    draft.epic = o.epicF.value || epics.find((e) => e.status !== 'done' && e.status !== 'diss')?.key || epics[0]?.key || ''
  }
  return { createIssue, resetDraft }
}

/* SPL-18 level 3: the open issue's subtasks (parent=), re-read after a
   frame that names it and after a subtask is added */
function useSubtasks(o: IssueDetailFormOpts) {
  const { api, detail } = o
  const subtasks = ref<Issue[]>([])
  const subtaskOpen = ref(false)
  async function loadSubtasks(issue: Issue | null) {
    if (!issue || issue.kind !== 'issue') { subtasks.value = []; return }
    try {
      const data = await withSessionRetry(api, () => api.listIssues({ filter: { parent: [issue.key] }, sort: 'created' }))
      if (detail.value?.key === issue.key) subtasks.value = (data.issues || []).map((row) => normalizeIssue(row))
    } catch {
      subtasks.value = []
    }
  }
  /* SPL-974: the dialog created it; show it now, then re-read the list */
  function onSubtaskCreated(sub: Issue) {
    void o.poke({ text: sub.title, where: { issue: true, issueKey: sub.key } })
    const parent = detail.value
    if (!parent || sub.parent !== parent.key) return
    if (!subtasks.value.some((s) => s.key === sub.key)) subtasks.value = [...subtasks.value, sub]
    void loadSubtasks(parent)
  }
  async function openParent() {
    await o.openIssueKey(detail.value?.parent || '')
  }
  return { subtasks, subtaskOpen, loadSubtasks, onSubtaskCreated, openParent }
}

export function useIssueDetailForm(o: IssueDetailFormOpts) {
  const draft = reactive(newDraft())
  const view = useFormView(o, draft)
  const { createIssue, resetDraft } = useCreate(o, draft)
  return {
    draft, ...view, createIssue, resetDraft, ...useSubtasks(o),
    ...useTextInputs(o, draft, createIssue),
    ...useFieldInputs(o, draft, view.activeLabels),
  }
}
