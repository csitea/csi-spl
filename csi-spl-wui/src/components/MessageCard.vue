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
    :aria-label="t('feed.card_aria', { who: whoOf(author), kind: kindLabel(String(msg.kind || 'note')) })"
    :aria-describedby="clickable ? 'feed-open-hint' : undefined"
    @click="onClick"
    @dblclick="onDblClick"
    @keydown="onKey"
    @contextmenu="onContextMenu"
  >
    <SpoolAvatar class="avatar" :id="author.id" :box="author.box" />
    <div>
      <!--
        CLE-3446 — the owner's settled row format, 2026-09-22: per message,
        sender -> recipient, and the arrow flips per row because BOTH ends are
        read from THIS message. A broadcast (ALL-0) has no recipient and shows
        the sender alone. SPL-981 (owner, 2026-09-26): so does a direct
        message (no channel): only the sender's avatar and name.
      -->
      <div class="msg-meta">
        <AgentBadge :id="author.id" :box="author.box || undefined" />
        <!-- specs/036 FR-011: the human typed this at the agent's terminal -->
        <span
          v-if="author.via"
          class="msg-via-terminal"
          data-testid="msg-typed-by"
          :data-typed-by="author.id"
          :data-via="author.via"
          :title="t('feed.typed_by.title', { who: whoOf(author), agent: author.via })"
        >{{ t('feed.typed_by.badge', { agent: author.via }) }}</span>
        <template v-if="recipient">
          <span class="msg-to-arrow" aria-hidden="true">→</span>
          <SpoolAvatar class="avatar--to" :id="recipient.id" :box="recipient.box" :size="20" />
          <AgentBadge :id="recipient.id" :box="recipient.box || undefined" />
        </template>
        <KindBadge :kind="String(msg.kind)" :msg="msg" />
        <span class="msg-time" :data-test="sinceMs == null ? 'msg-iso-ts' : undefined" :title="sinceMs == null ? formatIsoTs(at) : undefined">{{ time }}</span>
        <span
          v-if="edited"
          class="msg-edited"
          data-test="msg-edited"
          :title="t('feed.edit.marker_title', { at: String(msg.edited_at) })"
        >{{ t('feed.edit.marker') }}</span>
        <!-- Opening messages (is_parent 1) and replies (is_parent 0) are both
             this card. The emoji control is not gated on that flag. -->
        <span class="msg-actions">
          <!-- Tab: the card, then this link, then the menu. The emoji stays
               between them on screen (CSS order) and comes after the menu.
               The Open button paints immediately left of this link (order -1)
               and is reached after the emoji, so this link stays the first stop. -->
          <!-- SPL-982 (owner, topic 8296eeec): exactly "3 >>", no word; the
               name ("3 replies - Open topic") stays on aria-label and title -->
          <button
            v-if="count > 0 || alwaysTopic"
            class="replies"
            type="button"
            data-test="topic-replies"
            :aria-label="repliesName"
            :title="repliesName"
            @click.stop="openReplies"
          >
            {{ count }} &gt;&gt;
          </button>
          <button
            type="button"
            class="icon-btn msg-menu-btn"
            data-testid="msg-menu-btn"
            :aria-label="t('feed.msg_menu.label')"
            :title="t('feed.msg_menu.label')"
            :aria-expanded="menuOpen ? 'true' : 'false'"
            @click.stop="openMenuFromButton"
            @contextmenu.stop.prevent="openMenuFromButton"
          >
            <UiIcon name="menu" :size="16" />
          </button>
          <button
            type="button"
            class="icon-btn"
            data-testid="msg-emoji-btn"
            :aria-label="t('feed.emoji.add')"
            :title="t('feed.emoji.add')"
            :aria-expanded="pickerOpen ? 'true' : 'false'"
            :disabled="!msg.msg_id || !!msg.pending"
            @click.stop="openPickerFromButton"
          >
            <UiIcon name="smile" :size="16" />
          </button>
          <button
            v-if="topicLink && !titleOnly"
            class="icon-btn icon-btn--accent"
            type="button"
            data-test="open-topic"
            :aria-label="t('feed.open_topic')"
            :title="t('feed.open_topic')"
            @click="$emit('open-topic', msg)"
          >
            <UiIcon name="open" :size="16" />
          </button>
        </span>
        <!-- SPL-982 (owner, topic 8296eeec): the reactions sit in the header,
             3px after the Add-emoji icon; one chip per emoji, its count from 2
             people on, and its tooltip names who reacted -->
        <span v-if="chips.length && !titleOnly" class="msg-reactions" data-testid="msg-reactions">
          <button
            v-for="chip in chips"
            :key="chip.emoji"
            type="button"
            class="msg-reaction"
            data-testid="msg-reaction"
            :data-emoji="chip.emoji"
            :data-count="chip.count"
            :data-mine="chip.mine ? 'true' : undefined"
            :aria-label="chip.mine ? t('feed.emoji.mine', { emoji: chip.emoji }) : t('feed.emoji.chip', { emoji: chip.emoji, n: chip.count })"
            :title="chipWho(chip.actors)"
            :disabled="busy || !msg.msg_id || !!msg.pending"
            @click.stop="onReact(chip.emoji)"
          >
            <span aria-hidden="true">{{ chip.emoji }}</span>
            <span v-if="chip.showCount" class="msg-reaction__n">{{ chip.count }}</span>
          </button>
        </span>
        <span class="msg-meta-spacer" aria-hidden="true" />
      </div>
      <!--
        CLE-3445: the row BECOMES the box ("the msg becomes once again a
        textbox"), pre-filled with the old body. The rendered body is NOT
        replaced while saving and NOT replaced on failure — the new text
        reaches the screen only when the hub's answer arrives and the row
        itself changes underneath us (message-edit-v1 §5).
      -->
      <!--
        CLE-34989 (specs/033 FR-020..FR-026): a level-1 card in the middle pane
        takes the pane's height mode. `titles` is the first 90 characters on one
        line; `rows` clips the body and its attachments at 5 text rows, or at
        30% of the window when a picture is on the card, and a grip under it
        drags it taller (the omnibox's grip, re-drawn here, not shared); `full`
        and a host that passes no mode shows all of it.
      -->
      <div
        v-if="titleOnly"
        class="msg-title"
        data-testid="card-title"
      >
        <span class="msg-title__text" :title="title">{{ title }}</span>
        <FileAttachment
          v-for="(f, i) in files"
          :key="'title-' + String(f.file_id || f.path || i)"
          icon-only
          :file="f"
        />
      </div>
      <div
        v-else
        ref="clipEl"
        class="card-body"
        :class="{ 'card-clip': clipOn, 'card-clip--picture': clipOn && picture, 'card-clip--pic-text': clipOn && picture && userPx == null, 'card-clip--cut': clipOn && clipped }"
        :style="clipStyle"
        :data-clip="clipOn ? (clipped ? 'cut' : 'fits') : undefined"
        data-testid="card-body"
      >
        <div ref="clipInner" class="card-body__inner">
          <!-- SPL-985: @ opens the shared picker in the edit box too -->
          <div v-if="editing" class="mention-anchor">
            <textarea
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
              @input="draft = ($event.target as HTMLTextAreaElement).value; editMp.sync()"
              @click="editMp.sync"
              @keyup="editMp.sync"
              @blur="editMp.close"
              @keydown="onEditKey"
            />
            <MentionList :picker="editMp" />
          </div>
          <MessageBody v-else :body="String(msg.body || '')" />
          <FileAttachment
            v-for="(f, i) in files"
            :key="String(f.file_id || f.path || i)"
            :file="f"
          />
        </div>
      </div>
      <button
        v-if="clipOn && (clipped || userPx != null)"
        type="button"
        class="card-grip"
        data-testid="card-grip"
        :aria-label="t(clipped ? 'feed.clip.grip_more' : 'feed.clip.grip_less')"
        :title="t('feed.clip.grip_hint')"
        :aria-expanded="clipped ? 'false' : 'true'"
        @pointerdown="startGrip"
        @click.stop="onGripClick"
        @keydown="onGripKey"
      />
      <p v-if="editing" :id="editHintId" class="muted msg-edit-hint">
        {{ saving ? t('feed.edit.saving') : t('feed.edit.hint') }}
      </p>
      <p v-if="editError" class="msg-edit-error" role="alert" data-test="msg-edit-error">
        <UiIcon name="alert-triangle" :size="14" />
        <span>{{ t(editError) }}</span>
      </p>
      <p v-if="reactError && !titleOnly" class="msg-edit-error" role="alert" data-testid="msg-emoji-error">
        <UiIcon name="alert-triangle" :size="14" />
        <span>{{ reactError }}</span>
      </p>
    </div>
    <!-- mounted on open only: the menu is not in the initial JS (specs/027) -->
    <LazyMessageMenu
      v-if="menuOpen"
      :open="menuOpen"
      :x="menuPoint.x"
      :y="menuPoint.y"
      :editable="!!editable && !editing"
      :merge-prev="!!mergePrev"
      :merge-next="!!mergeNext"
      :parent="showParent"
      :topic="showTopicActions"
      @close="closeMenu()"
      @escape="rowEl?.focus({ preventScroll: true })"
      @open="onMenuOpen"
      @parent="onMenuParent"
      @edit="onMenuEdit"
      @copy="copyMessageLink"
      @merge-prev="onMerge('previous')"
      @merge-next="onMerge('next')"
      @delete="onMenuDelete"
      @archive="onMenuArchive"
      @delete-topic="onMenuDeleteTopic"
    />
    <!-- SPL-983: mounted when Delete is picked on a topic card, not before -->
    <LazyTopicDeleteDialog
      v-if="topicDeleteOpen"
      v-model:open="topicDeleteOpen"
      :msg-id="String(msg.msg_id || '')"
      @deleted="onTopicDeleted"
    />
    <EmojiPicker
      :open="pickerOpen"
      :x="pickerAt.x"
      :y="pickerAt.y"
      @close="pickerOpen = false"
      @choose="onReact"
    />
  </article>
</template>

<script setup lang="ts">
import { dmPeerOf, formatIsoTs, formatMsgListTs, formatTopicTs, headerRecipientOf, shownPerson } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import { fenceStateAt } from '~/utils/code-blocks.mjs'
import { activityOf } from '~/utils/feed.mjs'
import {
  beginEdit,
  commitEdit,
  editFailureKey,
  editKeyAction,
  isEdited,
  wantsDblClickEdit,
  wantsDelete,
  wantsEdit,
  withDraft,
} from '~/utils/msg-edit.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { useMentionPicker } from '~/composables/useMentionPicker'
import { useMentionPoke, type PokeWhere } from '~/composables/useMentionPoke'
import { useMessageMenu } from '~/composables/useMessageMenu'
import { useAccessStore } from '~/stores/access'
import { mayChangeTopic, topicErrorKey } from '~/utils/topic-archive.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { openThreadRow } from '~/utils/pane-scroll.mjs'
import { joinBodies, threadLineLink, topicPaneLink } from '~/utils/msg-menu.mjs'
import { reactionChips } from '~/utils/emoji.mjs'
import { useMessageEmoji } from '~/composables/useMessageEmoji'
import { typedByAuthor } from '~/utils/typed-by.mjs'
import {
  CARD_GRIP_STEP_ROWS,
  cardClipPx,
  cardDragPx,
  cardHasPicture,
  cardIsClipped,
  cardTitle,
} from '~/utils/card-clip.mjs'
import type { CardClipMode } from '~/composables/useCardClip'

import type { FileRef, ReactionUpdate, SpoolMessage } from '~/types/spool'

const props = defineProps<{
  msg: SpoolMessage
  count?: number
  alwaysTopic?: boolean
  posinset?: number
  setsize?: number
  topicLink?: boolean
  /** CLE-3427: the whole row opens its topic (pointer and keyboard). */
  clickable?: boolean
  /** the row the open topic is rooted at */
  selected?: boolean
  /** Date.now() at topic open (ticks while open): `yyyy-mm-dd HH:MM:SS sent <age>` */
  sinceMs?: number
  /** CLE-3445: offer the `e` shortcut on this row (author-only; the host decides). */
  editable?: boolean
  /** The older message in this same thread, when this row may be folded into it. */
  mergePrev?: SpoolMessage | null
  /** The newer message in this same thread, when this row may be folded into it. */
  mergeNext?: SpoolMessage | null
  /** The task the list itself shows (#lobby), so a card's link names the right topic. */
  currentTaskId?: string | null
  /** CLE-34989: titles / 5 rows / full. Omitted = show the whole card. */
  clipMode?: CardClipMode
  /** SPL-983: a middle-pane card, where Archive / Delete (the topic) may be offered. */
  topicMenu?: boolean
}>()
const emit = defineEmits<{ 'open-topic': [msg: SpoolMessage], edited: [msg: SpoolMessage], deleted: [msg: SpoolMessage], reacted: [update: ReactionUpdate] }>()

const repliesName = computed(() => `${t('feed.replies', { n: props.count ?? 0 }, props.count ?? 0)} - ${t('feed.open_topic')}`)
/** The replies link opens this topic on the right. The left tab stays as it was. */
function openReplies() {
  emit('open-topic', props.msg)
}

const { t, te } = useI18n({ useScope: 'global' })
const people = useHumanNames()
function whoOf(p: { id?: string, box?: string } | null | undefined) {
  if (!p?.id) return t('feed.unknown_author')
  return shownPerson(p.id, p.box, people.names.value)
}
/** specs/036 FR-011: who the row is shown as (the typist, for a terminal line). */
const author = computed(() => typedByAuthor(props.msg))
/** v:1 kind in words (feed.kind.*); an unknown kind shows as sent. */
const kindLabel = (k: string) => (te('feed.kind.' + k) ? t('feed.kind.' + k) : k)
/* CLE-3425: a topic card is ordered by its LAST activity, so it shows that
   moment — a card that sits above another must not print an older time. */
const at = computed(() => activityOf(props.msg))
/*
 * The message list prints `yyyy-mm-dd HH:MM`: no T, no seconds, no Z.
 * The thread pane keeps its own clock (`sinceMs`).
 */
const time = computed(() => (
  props.sinceMs != null
    ? formatTopicTs(at.value, props.sinceMs)
    : formatMsgListTs(at.value)
))
/* SPL-981: a direct message shows only its sender; channel rows keep sender -> recipient */
const recipient = computed(() => headerRecipientOf(props.msg))
const files = computed(() => (Array.isArray(props.msg.files) ? props.msg.files : []) as FileRef[])
const count = computed(() => props.count || 0)

/*
 * CLE-3427 — clicking the row opens its topic. The row already carried
 * tabindex="0" for the feed pattern, so the keyboard half is Enter / Space on
 * the focused row; the explicit "open topic" icon button stays as the
 * discoverable, screen-reader-named affordance.
 *
 * Two things a whole-row click must not eat: a click on something that is
 * itself interactive (a link in the body, the copy-code button, a file
 * attachment, the reply-count button — those handle themselves), and the
 * click that ENDS a text selection inside the message, which is how a reader
 * copies a line and never means "open the topic".
 */
const INTERACTIVE = 'a, button, input, textarea, select, label, summary, [role="button"], [contenteditable="true"]'

function selecting() {
  const sel = typeof window !== 'undefined' ? window.getSelection() : null
  return Boolean(sel && !sel.isCollapsed && String(sel).trim())
}

function onClick(ev: MouseEvent) {
  const el = ev.target as HTMLElement | null
  if (el && el.closest && el.closest(INTERACTIVE)) return
  if (selecting()) return
  /* A thread row is not clickable. The click selects it, so Delete and e
     apply to this message. A clickable row still opens its topic. */
  if (!props.clickable) {
    rowEl.value?.focus({ preventScroll: true })
    return
  }
  emit('open-topic', props.msg)
}

const MENU_PASS = 'a, button, input, textarea, select'

function onContextMenu(ev: MouseEvent) {
  const el = ev.target as HTMLElement | null
  if (el && el.closest && el.closest(MENU_PASS) && !el.closest('[data-testid="msg-menu-btn"]')) return
  ev.preventDefault()
  rowEl.value?.focus({ preventScroll: true })
  openMenuAt(ev.clientX, ev.clientY)
}

/** The same menu as a right-click, opened from the button on the row. */
function openMenuFromButton(ev: MouseEvent) {
  const btn = ev.currentTarget
  if (!(btn instanceof HTMLElement)) return
  pickerOpen.value = false
  if (menuOpen.value) {
    closeMenu()
    return
  }
  const r = btn.getBoundingClientRect()
  rowEl.value?.focus({ preventScroll: true })
  openMenuAt(r.left, r.bottom + 4)
}

function onMenuEdit() {
  closeMenu()
  startEdit()
}

function onMenuDelete() {
  closeMenu()
  void remove()
}

/** SPL-983: archive the topic. The card leaves every feed here at once; the
    hub's topic_archived frame tells the other tabs. */
async function onMenuArchive() {
  closeMenu()
  const id = String(props.msg.msg_id || '')
  if (!id || removing.value) return
  removing.value = true
  editError.value = ''
  try {
    await parentDeps.api.archiveTopic(id, true)
    dropEverywhere(id)
    emit('deleted', props.msg)
  } catch (e) {
    editError.value = topicErrorKey(e, 'archive')
  } finally {
    removing.value = false
  }
}

function onMenuDeleteTopic() {
  closeMenu()
  topicDeleteOpen.value = true
}

function onTopicDeleted(out: { msg_ids: string[] }) {
  for (const id of out.msg_ids) dropEverywhere(id)
  emit('deleted', props.msg)
}

/**
 * Fold this message into the neighbor. The neighbor keeps both bodies, older
 * first, and only then is this row removed — a failed edit leaves both rows.
 */
async function onMerge(which: 'previous' | 'next') {
  const other = which === 'previous' ? props.mergePrev : props.mergeNext
  if (!other || removing.value || editing.value) return
  if (!canEdit(props.msg) || !canEdit(other)) return
  const older = which === 'previous' ? String(other.body || '') : String(props.msg.body || '')
  const newer = which === 'previous' ? String(props.msg.body || '') : String(other.body || '')
  const body = joinBodies(older, newer)
  const keepId = String(other.msg_id || '')
  const dropId = String(props.msg.msg_id || '')
  if (!keepId || !dropId || keepId === dropId) return
  closeMenu()
  removing.value = true
  editError.value = ''
  try {
    if (body !== String(other.body || '')) {
      const row = await commit(keepId, body)
      emit('edited', row)
    }
    await removeMessage(dropId)
    emit('deleted', props.msg)
  } catch (e) {
    removing.value = false
    editError.value = editFailureKey(e)
  }
}

/* Open on a topic card opens its topic on the right, as the replies button
   does. A thread line is already in the open topic: it is selected instead,
   and the thread does not scroll. */
function onMenuOpen() {
  if (props.clickable) {
    openReplies()
    return
  }
  if (rowEl.value) openThreadRow(rowEl.value)
}

/* CLE-34996: a thread line (not a middle card) can go back to where its
   thread lives: the channel or DM with the parent card selected, or the
   issue whose discussion it is. Shown by the same rule as utils/parent-section.mjs parentSection: a channel, or a
   DM end that is not the viewer. What the item does is loaded when it is
   chosen, so it is not in the initial JS (specs/027, 210 KB gzip). */
const showParent = computed(() => !props.clickable
  && Boolean(String(props.msg.channel || '').trim().replace(/^#/, '') || dmPeerOf(props.msg, viewerId.value)))
const parentDeps = { api: useSpoolApi(), router: useRouter() }
async function onMenuParent() {
  closeMenu()
  const m = await import('~/utils/parent-section-open.mjs')
  await m.openParentSection(props.msg, { ...parentDeps, localePath, self: viewerId.value })
}

/* A topic card in the middle links to this page with its topic open on the
   right. A thread line links to the same, with its own id as the hash. */
function linkPath() {
  if (!props.clickable) return threadLineLink(props.msg, { path: route.path, query: route.query, pathFor: localePath })
  return topicPaneLink(props.msg, {
    path: route.path,
    query: route.query,
    currentTaskId: String(props.currentTaskId || ''),
  })
}

async function copyMessageLink() {
  const path = linkPath()
  if (!path || typeof window === 'undefined') return
  const url = new URL(path, window.location.origin).href
  try {
    await navigator.clipboard.writeText(url)
  } catch {
    const ta = document.createElement('textarea')
    ta.value = url
    ta.setAttribute('readonly', '')
    ta.style.position = 'fixed'
    ta.style.left = '0'
    ta.style.top = '0'
    ta.style.width = '1px'
    ta.style.height = '1px'
    ta.style.opacity = '0'
    document.body.appendChild(ta)
    ta.select()
    document.execCommand('copy')
    ta.remove()
  }
}

/** A double-click on a row opens the same editor as `e`: a thread line on
    the right, and a level-1 card in the middle too. The browser has just
    selected the word under the pointer; that selection is cleared before
    the editor takes the caret. */
function onDblClick(ev: MouseEvent) {
  const el = ev.target as HTMLElement | null
  const interactive = Boolean(el && el.closest && el.closest(INTERACTIVE))
  if (!wantsDblClickEdit(ev, {
    editable: Boolean(props.editable) && !editing.value,
    interactive,
  })) return
  ev.preventDefault()
  if (typeof window !== 'undefined') window.getSelection()?.removeAllRanges()
  startEdit()
}

function onKey(ev: KeyboardEvent) {
  /* CLE-3445: `e` on the focused row opens the editor. Checked BEFORE the
     open-topic keys so a row that is editable but not clickable still takes
     it, and guarded by the same target === currentTarget rule. */
  if (wantsEdit(ev, { editable: props.editable && !editing.value })) {
    ev.preventDefault()
    startEdit()
    return
  }
  /* Delete / Backspace on the focused thread row removes that message.
     preventDefault stops Backspace from walking the browser history. */
  if (wantsDelete(ev, { deletable: props.editable && !editing.value && !props.clickable })) {
    ev.preventDefault()
    void remove()
    return
  }
  if (!props.clickable) return
  if (ev.key !== 'Enter' && ev.key !== ' ' && ev.key !== 'Spacebar') return
  /* only the row itself: Enter inside a child control is that control's */
  if (ev.target !== ev.currentTarget) return
  ev.preventDefault()
  emit('open-topic', props.msg)
}

/*
 * CLE-3445 row E1 — editing in place.
 *
 * The state machine is utils/msg-edit.mjs and is unit-tested without a
 * browser; everything below is the textarea, the focus and the one await.
 * MessageComposer.vue is the reference for the key handling, NOT a thing to
 * reuse into a row: a row has no attach control, no `/search` mode and no
 * send button. It does share the one @ picker (SPL-985, useMentionPicker).
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
const { canEdit, commit, removeMessage, viewerId: editorId, dropEverywhere } = useMessageEdit()
/* SPL-983 (specs/041 §3.3): the card's author, the tenant owner or an admin.
   The hub re-checks; this only decides what the menu offers. */
const access = useAccessStore()
const showTopicActions = computed(() => Boolean(props.topicMenu) && mayChangeTopic(props.msg, editorId.value, access.me))
const topicDeleteOpen = ref(false)
const removing = ref(false)
const localePath = useLocalePath()
const route = useRoute()
/* The same message can sit in the middle list and the topic pane at once.
   The menu id has to be this card, not the msg_id, or both menus open. */
const menuKey = useId()
const { open: menuOpen, point: menuPoint, openAt: openMenuAt, close: closeMenu } = useMessageMenu(
  () => menuKey,
)
const { viewerId, setReaction, applyEverywhere } = useMessageEmoji()
const pickerOpen = ref(false)
const pickerAt = ref({ x: 0, y: 0 })
const busy = ref(false)
const reactError = ref('')
const chips = computed(() => reactionChips(props.msg.reactions, viewerId.value))
/** A chip's tooltip: who reacted, by the name the row would show. */
function chipWho(actors: string[]) {
  return actors.map((id) => shownPerson(id, '', people.names.value)).join(', ')
}

function openPickerFromButton(ev: MouseEvent) {
  const btn = ev.currentTarget
  if (!(btn instanceof HTMLElement)) return
  closeMenu()
  if (pickerOpen.value) {
    pickerOpen.value = false
    return
  }
  const r = btn.getBoundingClientRect()
  rowEl.value?.focus({ preventScroll: true })
  pickerAt.value = { x: r.left, y: r.bottom + 4 }
  pickerOpen.value = true
}

/** Add the glyph, or remove it when this member already added it. */
async function onReact(emoji: string) {
  if (busy.value || !props.msg.msg_id || props.msg.pending) return
  busy.value = true
  reactError.value = ''
  try {
    const update = await setReaction(props.msg, emoji)
    applyEverywhere(update)
    emit('reacted', update)
  } catch {
    reactError.value = t('feed.emoji.failed')
  } finally {
    busy.value = false
  }
}

/*
 * CLE-34989 — the card's height in the middle pane (utils/card-clip.mjs holds
 * the rule and its tests). The box is measured, not guessed: the line height
 * is read from the rendered body, so the 5 rows follow the font-size setting
 * (rem), and "clipped" is the content being taller than the box, so a short
 * card never shows a grip. Editing lifts the clip: the textarea sizes itself.
 */
const clipEl = ref<HTMLElement | null>(null)
const clipInner = ref<HTMLElement | null>(null)
const picture = computed(() => cardHasPicture(files.value))
const titleOnly = computed(() => props.clipMode === 'titles' && !editing.value)
const clipOn = computed(() => props.clipMode === 'rows' && !editing.value)
const title = computed(() => {
  const own = cardTitle(String(props.msg.body || ''))
  if (own) return own
  return cardTitle(files.value.map((f) => String(f.name || '')).filter(Boolean).join(', '))
})
/** A grip drag on this card, px; null = the automatic height. Never stored. */
const userPx = ref<number | null>(null)
const lineHeightPx = ref(0)
const viewportPx = ref(0)
const contentPx = ref(0)
const clipPx = computed(() => {
  if (!clipOn.value || !lineHeightPx.value) return null
  return cardClipPx({
    mode: 'rows',
    picture: picture.value,
    lineHeightPx: lineHeightPx.value,
    viewportPx: viewportPx.value,
    userPx: userPx.value,
  })
})
const clipped = computed(() => clipPx.value != null && cardIsClipped(contentPx.value, clipPx.value))
/* Before the first measurement the stylesheet's own rows / 30vh cap holds. */
const clipStyle = computed(() => (clipPx.value != null ? { maxHeight: `${clipPx.value}px` } : undefined))

function measure() {
  if (typeof window === 'undefined') return
  const inner = clipInner.value
  if (!inner) return
  const body = inner.querySelector<HTMLElement>('.msg-body') || inner
  const lh = parseFloat(getComputedStyle(body).lineHeight)
  const fs = parseFloat(getComputedStyle(body).fontSize) || 14
  lineHeightPx.value = Number.isFinite(lh) && lh > 0 ? lh : fs * 1.45
  viewportPx.value = window.innerHeight
  /* a picture card caps its text at 5 rows inside the 30% box, so the
     picture shows under it; the text cut counts toward "clipped" too */
  const textCut = body !== inner ? Math.max(0, body.scrollHeight - body.clientHeight) : 0
  contentPx.value = Math.ceil(inner.scrollHeight + textCut)
}

let clipObserver: ResizeObserver | null = null
function stopObserving() {
  clipObserver?.disconnect()
  clipObserver = null
  if (typeof window !== 'undefined') window.removeEventListener('resize', measure)
}
function startObserving() {
  stopObserving()
  if (typeof window === 'undefined' || !clipOn.value || !clipInner.value) return
  measure()
  if (typeof ResizeObserver !== 'undefined') {
    clipObserver = new ResizeObserver(() => measure())
    clipObserver.observe(clipInner.value)
  }
  window.addEventListener('resize', measure)
}
watch([clipOn, clipInner], () => { void nextTick(startObserving) })
onMounted(() => startObserving())
onBeforeUnmount(stopObserving)
/* Another mode, or another message under this card: back to the automatic height. */
watch(() => [props.clipMode, String(props.msg?.msg_id || '')], () => { userPx.value = null })

let gripDragged = false
function startGrip(ev: PointerEvent) {
  const box = clipEl.value
  const handle = ev.currentTarget
  if (!box || !(handle instanceof HTMLElement)) return
  ev.preventDefault()
  measure()
  handle.setPointerCapture(ev.pointerId)
  gripDragged = false
  const startY = ev.clientY
  const startH = box.getBoundingClientRect().height
  const move = (e: PointerEvent) => {
    const dy = e.clientY - startY
    if (!gripDragged && Math.abs(dy) < 3) return
    gripDragged = true
    userPx.value = cardDragPx(startH, dy, lineHeightPx.value, contentPx.value)
  }
  const end = () => {
    handle.removeEventListener('pointermove', move)
    handle.removeEventListener('pointerup', end)
    handle.removeEventListener('pointercancel', end)
  }
  handle.addEventListener('pointermove', move)
  handle.addEventListener('pointerup', end)
  handle.addEventListener('pointercancel', end)
}

/** A click (or Enter / Space) on the grip: all of it, or back to the automatic height. */
function onGripClick() {
  if (gripDragged) {
    gripDragged = false
    return
  }
  measure()
  userPx.value = clipped.value ? contentPx.value : null
}

/** Arrow Down / Up: two rows more or less, from one row to the whole card. */
function onGripKey(ev: KeyboardEvent) {
  if (ev.key !== 'ArrowDown' && ev.key !== 'ArrowUp') return
  ev.preventDefault()
  ev.stopPropagation()
  measure()
  const now = clipEl.value?.getBoundingClientRect().height || clipPx.value || 0
  const step = lineHeightPx.value * CARD_GRIP_STEP_ROWS * (ev.key === 'ArrowDown' ? 1 : -1)
  userPx.value = cardDragPx(now, step, lineHeightPx.value, contentPx.value)
}

const draft = computed({
  get: () => edit.value?.draft ?? '',
  set: (v: string) => { edit.value = withDraft(edit.value, v) },
})
const { poke } = useMentionPoke()
/* K4: where this message lives - an issue comment, a channel, or a DM between its two ends */
function editWhere(): PokeWhere {
  const m = props.msg
  const taskId = String(m.task_id || '')
  const channel = String(m.channel || '')
  /* 'issues' = utils/parent-section.mjs ISSUE_CHANNEL, which must stay out of the initial chunk */
  if (channel === 'issues') return { issue: true, taskId }
  if (channel) return { channel, taskId }
  const to = String(m.to || '')
  if (!to || to === '@channel') return { channel: '', taskId }
  return { ends: [String(m.from || ''), to], taskId }
}
const editMp = useMentionPicker({
  text: draft,
  el: editEl,
  blocked: () => fenceStateAt(draft.value, editEl.value?.selectionStart ?? draft.value.length).inCode,
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
  reactError.value = ''
  pickerOpen.value = false
  busy.value = false
})

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

onMounted(() => {
  if (typeof window === 'undefined') return
  const hash = decodeURIComponent(window.location.hash.replace(/^#/, ''))
  if (hash && hash === String(props.msg?.msg_id || '')) rowEl.value?.focus({ preventScroll: true })
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
  nextTick(() => rowEl.value?.focus({ preventScroll: true }))
}

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
    /* SPL-985 K3: only a mention the edit ADDED pokes, never one already told */
    void poke({ text: body, before: state.original, where: editWhere() })
    closeEdit()
  } catch (e) {
    saving.value = false
    editError.value = editFailureKey(e)
    nextTick(() => editEl.value?.focus())
  }
}
</script>

<style scoped>
.mention-anchor { position: relative; min-width: 0; }
/*
 * CLE-3446 — the recipient half of the owner's row format.
 *
 * The inline avatar deliberately does NOT take the shared `.avatar` class:
 * that rule is the row's 36px left gutter (`width: 36px; height: 36px`), and
 * this one is a 20px inline mark. It would have LOOKED right anyway, because
 * SpoolAvatar writes width/height as an inline style and inline styles beat a
 * stylesheet -- which is exactly the kind of accident that survives review and
 * then breaks the day someone drops the inline style.
 *
 * `.msg-meta` is `align-items: baseline` (shared, other rows rely on it), so
 * both inline marks centre themselves rather than sitting on the text baseline.
 */
.avatar--to { align-self: center; }
.msg-to-arrow {
  align-self: center;
  color: var(--color-muted);
  font-size: 0.75rem;
  line-height: 1;
}
/* SPL-982 (owner, topic 8296eeec): the emoji sits about 5px after the time;
   Open topic, the replies link and the menu stay on the right. The actions
   are `display: contents`, so their buttons are .msg-meta items and `order`
   paints them; the DOM (and so Tab: replies, menu, emoji, open) is unchanged.
   The emoji's glyph is 16px in a 32px icon-btn (8px padding) after the row's
   8px gap: -11px puts the glyph 5px after the time. */
/* the row's text and its 32px buttons share one centre line in a card, so
   the emoji beside the time sits level with it (the shared .msg-meta rule in
   main.css stays baseline for every other row).
   SPL-982: the header is ONE line, so the chips stay beside the emoji in a
   narrow pane (the issue discussion is ~355px): the names give way first
   (ellipsis, full text on hover), and many chips wrap inside their own box */
.msg-meta { align-items: center; flex-wrap: nowrap; }
.msg-meta > :deep(.msg-author) { flex: 0 1 auto; min-width: 2.5em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.msg-meta > .msg-time { flex: 0 0 auto; }
/* a phone keeps the old wrap: the header may take two lines, never the page */
@media (max-width: 30rem) {
  .msg-meta { flex-wrap: wrap; }
}
.msg-actions { display: contents; }
.msg-actions > * { align-self: center; }
.msg-actions .icon-btn[data-testid="msg-emoji-btn"] { order: 1; margin-inline-start: -11px; }
/* the reactions follow the emoji (same order, later in the DOM): the chips
   start 3px after its glyph (8px button padding + 8px row gap - 13px) and
   wrap inside themselves, so many chips never widen the card */
.msg-meta > .msg-reactions { order: 1; margin-inline-start: -13px; flex: 0 1 auto; align-self: center; }
/* "(edited)" follows them; the spacer then pushes Open topic, the replies
   link and the menu to the right */
.msg-meta > .msg-edited { order: 2; }
.msg-meta-spacer { order: 2; flex: 1 1 0; min-width: 0; }
.msg-actions [data-test="open-topic"] { order: 3; }
.msg-actions .replies { order: 4; margin-top: 0; align-self: center; white-space: nowrap; }
.msg-actions .msg-menu-btn { order: 5; }
.msg-menu-btn { align-self: center; }
.msg-reactions {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 4px;
}
.msg-reaction {
  appearance: none;
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-height: 28px;
  padding: 2px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  background: transparent;
  color: var(--color-fg);
  font: inherit;
  font-size: 0.875rem;
  line-height: 1;
  cursor: pointer;
}
.msg-reaction[data-mine="true"] {
  background: var(--color-selected);
  border-color: var(--color-border-strong, var(--color-border));
}
.msg-reaction:hover,
.msg-reaction:focus-visible {
  background: var(--color-surface-hover);
}
.msg-reaction__n { font-variant-numeric: tabular-nums; font-size: 0.75rem; }
/*
 * CLE-34989 — the middle pane's clipped card. The fallback cap is the same
 * rule as utils/card-clip.mjs (5 rows of the body's 0.875rem x 1.45, or 30%
 * of the window with a picture) so the card is already tight before the first
 * measurement; once measured, the inline max-height takes over. rem, so the
 * font-size setting moves it.
 */
.card-clip {
  max-height: calc(5 * 1.45 * 0.875rem);
  overflow: hidden;
}
.card-clip--picture { max-height: max(calc(5 * 1.45 * 0.875rem), 30vh); }
/* with a picture the text keeps its own 5 rows, so the picture is in view;
   a grip drag or Enter lifts it with the rest */
.card-clip--pic-text :deep(.msg-body) {
  max-height: calc(5 * 1.45 * 0.875rem);
  overflow: hidden;
}
/* clipped: the last line fades out, and the grip under it says there is more */
.card-clip--cut {
  -webkit-mask-image: linear-gradient(to bottom, #000 calc(100% - 1.5em), transparent);
  mask-image: linear-gradient(to bottom, #000 calc(100% - 1.5em), transparent);
}
/* the omnibox grip (main.css .omnibox-resize), drawn under a card */
.card-grip {
  display: block;
  width: 100%;
  height: 12px;
  margin: 0;
  padding: 0;
  border: 0;
  border-radius: var(--radius-sm);
  background: transparent;
  color: var(--color-muted);
  cursor: ns-resize;
  touch-action: none;
}
.card-grip::after {
  content: "";
  display: block;
  width: 28px;
  height: 3px;
  margin: 4px auto 0;
  border-radius: var(--radius-pill);
  background: currentColor;
}
.card-grip:hover { color: var(--color-fg); }
.msg-title {
  display: flex;
  align-items: center;
  gap: 4px;
  margin: 2px 0 0;
  font-size: 0.875rem;
  line-height: 1.45;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.msg-title__text {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
</style>
