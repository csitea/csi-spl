<template>
  <!-- SPL-991: docked on a phone, the form stays in TopBar's omnibox slot,
       which turns `display: contents` for it (TopBar keys on .composer--dock) -->
  <form
    ref="formEl"
    class="composer"
    :class="{ omnibox, 'omnibox--global': global, 'omnibox--search': searchMode, 'composer--dock': docked, 'omnibox--bottom': bottom && !docked }"
    :data-docked="docked ? 'true' : undefined"
    :data-mode="modeAttr"
    :data-yield="docked && stack.sheetOpen.value ? 'true' : undefined"
    :data-phone-pos="docked ? phonePos : undefined"
    :data-phone-size="docked && phoneShare != null ? 'set' : undefined"
    :style="docked && phoneShare != null ? { [phonePos === 'right' ? '--dock-width-share' : '--dock-field-share']: String(phoneShare) } : undefined"
    @submit.prevent="onSend"
  >
    <!-- owner, t1 2026-10-02: the grip that drags the phone dock to the
         top, the right corner or back to the bottom (OmniboxGrip) -->
    <OmniboxGrip v-if="docked" :box="formEl" />
    <div class="composer-box">
      <!-- 022 FR-012: operator autocomplete in /search mode (catalogue: search-v1 §6) -->
      <ul
        v-if="opPickerOpen"
        ref="opListEl"
        :id="opListId"
        class="mention-list op-list"
        role="listbox"
        data-test="search-operators"
        :aria-label="t('search.operator_suggestions')"
      >
        <li v-for="(c, i) in opCandidates" :key="c.insert">
          <button
            :id="opListId + '-' + i"
            type="button"
            role="option"
            class="mention-item"
            :class="{ active: i === opIdx }"
            :aria-selected="i === opIdx"
            @mousedown.prevent="pickOp(c.insert)"
          >
            <code class="mention-label">{{ c.insert.trim() }}</code>
            <span v-if="c.label !== c.insert.trim()" class="muted op-example">{{ c.label }}</span>
          </button>
        </li>
      </ul>
      <!-- SPL-985: the one @ picker (useMentionPicker), shared with every text field -->
      <MentionList :picker="mp" placement="inline" />
      <ul
        v-if="inPickerOpen"
        ref="inListEl"
        class="mention-list"
        role="listbox"
        data-test="topic-in-suggestions"
        :aria-label="t('nav.topics')"
      >
        <li v-for="(row, i) in inCandidates" :key="row.taskId">
          <button
            type="button"
            role="option"
            class="mention-item"
            :class="{ active: i === inIdx }"
            :aria-selected="i === inIdx"
            @mousedown.prevent="pickIn(row)"
          >
            <span class="mention-label">{{ row.title }}</span>
            <span v-if="row.channel" class="muted">#{{ row.channel }}</span>
          </button>
        </li>
      </ul>
      <span v-if="searchMode" class="omnibox-mode" data-test="omnibox-mode">
        <UiIcon name="search" :size="14" />{{ t('search.mode_chip') }}
      </span>
      <div
        class="omnibox-field"
        :class="{ 'has-mode-glyph': modeGlyph, 'has-target-chip': chip }"
        :style="chip ? { '--chip-w': chipW + 'px' } : undefined"
        ref="fieldEl"
      >
        <!-- owner, t1 3d6d945d (2026-10-02, option "A"): one glyph inside the
             box at its start says where the post goes - "#" a new topic, the
             tree (an upside-down F) into the open thread or issue. Its name is
             the mode's own words; the placeholder and GO say it too. -->
        <span
          v-if="modeGlyph"
          class="composer-mode-glyph"
          data-test="composer-mode-glyph"
          :data-glyph="modeGlyph"
          role="img"
          :aria-label="modeText"
          :title="modeText"
        ><UiIcon :name="modeGlyph" :size="16" /></span>
        <!-- 080 FR-006: while the box holds text, a chip after the glyph
             names where Enter sends (#feedback, @HUM-3, Reply · <title>, New
             topic · #lobby), top and bottom positions alike; a click opens it
             (Q3). Inside the box, never a line over it (owner, t1 7d777e79 /
             dd98f8d7). On the phone dock (085 FR-001) it shows on focus too,
             cut to 12 characters, the full words in title and aria-label.
             Replaces the bottom dock's "where it goes" line (c6994436). -->
        <button
          v-if="chip"
          ref="chipEl"
          type="button"
          class="composer-target-chip"
          data-test="composer-target-chip"
          :data-mode="chipMode"
          :title="chipFull"
          :aria-label="docked ? chipFull : undefined"
          @mousedown.prevent
          @click="openChip"
        >{{ chipText }}</button>
        <!-- 085 FR-004: on the phone dock the "?" is the Search button - the
             magnifier, named "Search"; a tap enters search mode, focuses the
             field and opens the operator list, a second tap leaves it -->
        <button
          v-if="global"
          type="button"
          class="search-syntax-btn"
          data-test="search-syntax-help"
          :aria-expanded="syntaxOpen ? 'true' : 'false'"
          :aria-controls="syntaxId"
          :aria-pressed="docked ? (searchMode ? 'true' : 'false') : undefined"
          :aria-label="docked ? t('search.title') : t('search.help_button')"
          :title="docked ? t('search.title') : t('search.help_button')"
          @mousedown.prevent
          @click="onSyntaxButton"
        ><UiIcon v-if="docked" name="search" :size="18" /><template v-else>?</template></button>
        <div
          v-if="global && syntaxOpen"
          :id="syntaxId"
          class="search-syntax"
          data-test="search-syntax-panel"
          role="dialog"
          :aria-label="t('search.help_title')"
          @mousedown.prevent
        >
          <!-- 085 FR-005: the key hints the short phone placeholder dropped -->
          <ul v-if="docked" class="search-syntax__keys" data-test="search-phone-hints">
            <li v-for="h in phoneHints" :key="h">{{ h }}</li>
          </ul>
          <p class="muted">{{ t('search.help_intro') }}</p>
          <p class="muted">{{ t('search.help_content') }}</p>
          <p class="search-syntax__label">{{ t('search.help_operators') }}</p>
          <ul>
            <li v-for="row in syntaxRows" :key="row.op">
              <button type="button" class="search-syntax__op" @click="insertOperator(row.op)">
                <code dir="ltr">{{ row.op }}</code>
                <span v-if="te(row.hintKey)">{{ t(row.hintKey) }}</span>
                <span class="muted" dir="ltr">/search: {{ row.example }}</span>
              </button>
            </li>
          </ul>
        </div>
        <textarea
          ref="inputEl"
          :aria-label="global ? t('search.omnibox_label') : omnibox ? t('composer.omnibox_label') : t('composer.message_label')"
          :aria-controls="opPickerOpen ? opListId : undefined"
          :aria-activedescendant="opPickerOpen && opIdx >= 0 ? opListId + '-' + opIdx : undefined"
          :aria-keyshortcuts="global ? '/' : undefined"
          v-model="text"
          :rows="global ? 1 : 2"
          :class="{ 'in-code': inCode }"
          :placeholder="placeholder"
          :aria-describedby="global ? `${hintId} ${slashHintId}` : hintId"
          autocomplete="off"
          spellcheck="true"
          :enterkeyhint="docked ? (submitMode === 'enter' ? 'send' : 'enter') : undefined"
          @keydown="onKeydown"
          @input="syncMention"
          @click="syncMention"
          @keyup="syncMention"
          @focus="onOmniboxFocus"
          @blur="onOmniboxBlur"
          @paste="onPaste"
        />
        <p :id="hintId" class="code-hint muted" aria-live="polite">{{ inCode ? t('composer.code_hint') : '' }}</p>
        <p v-if="global" :id="slashHintId" class="sr-only">{{ t('search.slash_shortcut') }}</p>
        <ul v-if="picked.length" class="file-chips">
          <li v-for="(f, i) in picked" :key="f.name + i">
            <img
              v-if="thumbs.get(f)"
              class="file-chip-thumb"
              data-test="composer-file-thumb"
              :src="thumbs.get(f)"
              :alt="f.name"
            >
            <UiIcon v-else :name="fileKind(f.name).icon" :size="16" class="file-kind-icon" :data-kind="fileKind(f.name).kind" />
            {{ f.name }} <small>{{ t('composer.file_bytes', { n: f.size }) }}</small>
            <button
              type="button"
              class="icon-btn"
              data-test="composer-remove-file"
              :aria-label="t('composer.remove_file', { name: f.name })"
              :title="t('composer.remove_file', { name: f.name })"
              @click="picked.splice(i, 1)"
            >
              <UiIcon name="x" :size="14" />
            </button>
          </li>
        </ul>
        <!-- a size refusal is a validation message, not a failure with a
             reference to quote, so it is NOT an ErrorNotice: minting an
             ERR-CLIENT-… into the diagnostics journal for "this snippet is
             long" would bury the failures that journal exists for -->
        <p v-if="pickLost && !docked" class="composer-too-big" role="status" data-testid="attach-nothing">
          <UiIcon name="alert-triangle" :size="16" />
          <span>{{ t('composer.attach_nothing') }}</span>
        </p>
        <!-- e3e9ca61: on a phone the same notice is a TOP snackbar with a
             close, a timeout and tap-outside-to-dismiss - inside the dock it
             had none of them, stayed up and read as a frozen app -->
        <Teleport v-if="pickLost && docked" to="body">
          <UndoSnackbar
            :text="t('composer.attach_nothing_touch')"
            :close-label="t('snackbar.dismiss')"
            :show-undo="false"
            :duration="ATTACH_NOTICE_MS"
            icon="alert-triangle"
            testid="attach-nothing"
            @dismiss="pickLost = false"
          />
        </Teleport>
        <p v-if="sizeError" class="composer-too-big" role="alert" data-testid="composer-too-big">
          <UiIcon name="alert-triangle" :size="16" />
          <span>{{ t(sizeError.key, sizeError.params) }}</span>
        </p>
        <button
          v-if="global"
          type="button"
          class="omnibox-resize"
          data-test="omnibox-resize"
          tabindex="-1"
          :aria-label="t('composer.resize')"
          @pointerdown="startResize"
        />
      </div>
      <div class="composer-row">
        <!-- Send stays in the tab order. Attach is a pointer target only
             (tabindex=-1), the same as the resize grip. The file input is
             not a tab stop, and a disabled Send would leave the tab order. -->
        <!-- topic d4bc9db4 (owner): the phone dock is Back | Attach | Send,
             Attach in the middle. Back is the top bar's "<" (MobileBack: the
             same stack.pop()), in thumb reach while the keyboard is up; a
             photo is taken through Attach (the OS picker offers the camera) -->
        <button
          v-if="docked"
          type="button"
          tabindex="-1"
          class="dock-back"
          data-testid="dock-back"
          :disabled="stack.level.value <= 1"
          @mousedown.prevent
          @click.stop="stack.pop()"
          :aria-label="t('mobile.back')"
          :title="t('mobile.back')"
        ><UiIcon name="chevron-left" :size="22" class="dock-back__glyph" /></button>
        <button
          v-if="!searchMode"
          type="button"
          tabindex="-1"
          class="attach"
          data-testid="attach"
          @mousedown.prevent
          @click="openFiles"
          :aria-label="t('composer.attach')"
          :title="t('composer.attach')"
        ><UiIcon name="paperclip" :size="18" /></button>
        <input
          v-if="!searchMode"
          ref="fileEl"
          type="file"
          multiple
          hidden
          tabindex="-1"
          data-testid="attach-input"
          @change="onFiles"
          @cancel="onPickCancel"
        >
        <!-- SPL-977: one GO icon sends, or runs the /search; its tooltip is
             drawn on top of everything, under the button (the bar is at the
             window's top edge, so there is no room above it) -->
        <button
          v-if="searchMode"
          type="submit"
          class="composer-go"
          data-test="omnibox-search"
          :disabled="!searchQueryOf(text)"
          :aria-label="t('composer.go')"
        ><UiIcon name="go" :size="20" /><span class="composer-go__tip" data-test="go-tip" aria-hidden="true">{{ t('composer.go') }}</span></button>
        <button
          v-else
          type="submit"
          class="composer-send composer-go"
          data-testid="send"
          @mousedown.prevent
          :aria-disabled="cannotSend ? 'true' : 'false'"
          :aria-label="busy ? t('composer.sending') : t(sendKey)"
        ><UiIcon name="go" :size="20" /><span class="composer-go__tip" data-test="go-tip" aria-hidden="true">{{ busy ? t('composer.sending') : t(sendKey) }}</span></button>
      </div>
    </div>
  </form>
</template>

<script setup lang="ts">
import UndoSnackbar from '~/components/UndoSnackbar.vue'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import { useRosterStore } from '~/stores/roster'
import { useViewerStore } from '~/stores/viewer'
import { useOmniboxStore } from '~/stores/omnibox'
import { useSessionStore } from '~/stores/session'
import { draftPlaceOf, draftText, registerDraftSource, saveDraft } from '~/utils/drafts.mjs'
import { closeOpenFence, exitFence, fenceStateAt } from '~/utils/code-blocks.mjs'
import { useSubmitKey } from '~/composables/useSubmitKey'
import { omniboxFocusHeight, omniboxRememberHeight } from '~/utils/omnibox-size.mjs'
import { sendLimitError } from '~/utils/code-view.mjs'
import { fileKind, isPreviewableImage, readDataUrl } from '~/utils/file-preview.mjs'
import { carriesFiles, filesOf, pasteAttaches } from '~/utils/transfer-files.mjs'
import { useSidePane } from '~/composables/useSidePane'
import { useMentionPicker } from '~/composables/useMentionPicker'
import { useKeyboardInset, usePhone } from '~/composables/useTouchUi'
import { useStatusStripHeight } from '~/composables/useStatusStrip'
import { useMobileStack } from '~/composables/useMobileStack'
import { COMPOSER_FOCUS_EVENT } from '~/utils/touch-ui.mjs'
import { onOutsideTap } from '~/utils/outside-tap.mjs'
import { perfKeydown, perfSendStart } from '~/utils/perf-mark.mjs'
import { parseOmnibox } from '~/utils/feed.mjs'
import { chipLabel, composerModeLabel, phoneChipLabel, composerSendKey, dockTargetHint } from '~/utils/omnibox-topic.mjs'
import { omniboxMaxHeight, resizeHeight } from '~/utils/omnibox-dock.mjs'
import { useOmniboxPhonePos } from '~/composables/useOmniboxPhonePos'
import { switchPaneOf } from '~/utils/sidebar-tabs.mjs'
import { applyCompletion, completeOperators, omniboxMode, omniboxTextLeavingSearch, operatorHelpRows, operatorTokenAt, OP_PICKER_CAP, searchQueryOf, type SearchOperator } from '~/utils/search.mjs'
import {
  activeInQuery,
  filterTopicTitles,
  insertInClause,
  resolveInClause,
  topicChoices,
} from '~/utils/topic-in.mjs'

const props = withDefaults(defineProps<{
  /**
   * SPL-991: on a phone (<= 820 px) the one composer docks at the bottom,
   * above the on-screen keyboard - on every level since SPL-1005.
   * Default true (withDefaults: an absent boolean prop would read false).
   */
  dock?: boolean
  placeholder?: string
  parentTaskId?: string
  busy?: boolean
  /** 013 Top Omnibox: Ctrl or Cmd+Enter sends; Enter inserts a line; `/search <q>` still submits on Enter; Esc clears the filter. */
  omnibox?: boolean
  /**
   * 022 top-bar Omnibox: `/search <q>` is a GLOBAL search (emit search, keep the
   * line for refining), operators autocomplete, Esc on an empty line → dismiss,
   * ArrowDown in search mode → results.
   */
  global?: boolean
  /** 022: no page send target — plain text cannot be sent (search still works) */
  sendBlocked?: boolean
  /** 022: the operator catalogue (search-v1 §6) */
  operators?: SearchOperator[]
  /** SPL-1003: the page's send target for the dock's hint (omnibox target `dock()`) */
  dockTarget?: { reply: boolean, target: string, comment?: boolean, dm?: boolean } | null
  /**
   * Topic c6994436 (lane B): TopBar moved this box into the bottom dock under
   * the middle pane (> 820 px, Settings -> Behaviour). The pickers, the GO
   * tip and the send error open UPWARD, the grip drags the top edge.
   */
  bottom?: boolean
}>(), { dock: true })
const emit = defineEmits<{
  send: [text: string, parentTaskId?: string, files?: File[], channelId?: string]
  search: [q: string]
  dismiss: []
  results: []
  /** mounted: TopBar's deferred Teleport mounts this after the bar (c6994436) */
  ready: [box: { setText: (s: string) => void }]
}>()
const picked = ref<File[]>([])
/* a picked picture shows a thumbnail before it is sent (a data: URL: the
   deployed CSP admits no blob:); every other file shows its type icon */
const thumbs = shallowRef(new Map<File, string>())
watch(picked, async (files) => {
  const next = new Map<File, string>()
  for (const f of files) {
    const had = thumbs.value.get(f)
    if (had) next.set(f, had)
    else if (isPreviewableImage(f.name, f.size)) next.set(f, await readDataUrl(f))
  }
  thumbs.value = next
}, { deep: true })
const roster = useRosterStore()
const viewer = useViewerStore()
const channelFeed = useChannelStore()
const liveMain = useLiveFeed('main')
const text = ref('')
const inputEl = ref<HTMLTextAreaElement | null>(null)

/*
 * 080 FR-001..FR-003: one draft per place. The page's omnibox target names
 * its place (`ch:` / `dm:` / `t:`); a change of place keeps the text under
 * the old one and brings back the new one's, typing keeps it (300 ms), and
 * the box a send empties drops it - a failed send puts the text back (TopBar
 * restore), which keeps it again. A search line is never a draft. Only the
 * top-bar box keeps drafts.
 */
const omniboxTargets = useOmniboxStore()
const session = useSessionStore()
const DRAFT_SAVE_MS = 300
const draftPlace = computed(() => (props.global ? draftPlaceOf(omniboxTargets.target?.place?.() ?? '') : ''))
const draftHuman = computed(() => String(session.claims?.hum || ''))
/* what the store holds for this place: a load is not a save */
let draftStored = ''
let draftTimer: ReturnType<typeof setTimeout> | null = null
let draftPending: (() => void) | null = null
function isDraftText(s: string) {
  return omniboxMode(s) !== 'search' && switchPaneOf(s) === null
}
function cancelDraftSave() {
  if (draftTimer) clearTimeout(draftTimer)
  draftTimer = null
  draftPending = null
}
function flushDraftSave() {
  const run = draftPending
  cancelDraftSave()
  run?.()
}
watch(text, (s) => {
  const human = draftHuman.value
  const place = draftPlace.value
  /* a later key wins: `/` then `/s` (a search) must not keep `/` */
  cancelDraftSave()
  if (!import.meta.client || !human || !place || !isDraftText(s) || s === draftStored) return
  draftPending = () => {
    saveDraft(undefined, human, place, s)
    draftStored = s
  }
  draftTimer = setTimeout(flushDraftSave, DRAFT_SAVE_MS)
})
watch([draftPlace, draftHuman], ([place, human], [, oldHuman]) => {
  if (!import.meta.client || !props.global) return
  const s = text.value
  if (human === oldHuman) flushDraftSave()
  /* signed out or another member: nothing more is written for the old one */
  else cancelDraftSave()
  if (!isDraftText(s)) return
  /* the session arrived after the reader started typing: keep that text */
  if (!oldHuman && s) return
  draftStored = human && place ? draftText(undefined, human, place) : ''
  if (draftStored !== s) setText(draftStored)
}, { immediate: true })
onBeforeUnmount(flushDraftSave)
onBeforeUnmount(registerDraftSource(() => draftPending && { human: draftHuman.value, place: draftPlace.value, text: text.value }))

/*
 * SPL-991 — the phone dock. The composer is the one TopBar mounts; on a phone
 * it leaves the bar and pins itself to the bottom edge, `--kb-inset` above it
 * (useKeyboardInset: the visualViewport keyboard height, iOS Safari and
 * Android Chrome), full width, 44 px Back / Attach / Send. Its height goes
 * to `--composer-dock-h` on <html> (0 when not docked), so the panes pad
 * their last card clear of it (M1) and TopBar lifts its send error over it
 * (M2). SPL-1005: every level, the section chooser included.
 */
const formEl = ref<HTMLFormElement | null>(null)
const phone = usePhone()
const kbInset = useKeyboardInset()
const stack = useMobileStack()
/* SPL-1005 (owner, topic 9b58a27b): the floating GO is gone, so the dock is
   the phone's only omnibox - it shows on EVERY level, the section chooser
   and pages with no send target included (there `/search` still works and
   plain text says it cannot be sent) */
const docked = computed(() => Boolean(props.global) && props.dock && phone.value)
/* owner, t1 2026-10-02: the dock's place on the phone (its grip moves it) */
const { pos: phonePos, size: phoneSize } = useOmniboxPhonePos()
/* owner, t1 21:53Z: its size there (the grip's size handle or the menu) */
const phoneShare = computed(() => phoneSize.value[phonePos.value] ?? null)
/* phones only: a desktop never loads the grip */
const OmniboxGrip = defineAsyncComponent(() => import('~/components/OmniboxGrip.vue'))
/* SPL-1003: where the next post goes, shown above the docked box */
const dockHint = computed(() => dockTargetHint(props.dockTarget, text.value))
let dockObserver: ResizeObserver | null = null
/* CLE-77888: the dock sits on the phone's bottom status strip, so the
   height it reports is the two together (the strip is 0 while it is gone) */
const stripH = useStatusStripHeight()
let dockPx = 0
function setDockHeight(px: number) {
  dockPx = px
  if (typeof document === 'undefined') return
  /* at the top the box no longer covers the bottom: the panes pad only the
     strip there, and start under the box (--composer-dock-top-h, main.css) */
  const top = px > 0 && phonePos.value === 'top'
  const total = px > 0 ? px + stripH.value : 0
  const root = document.documentElement.style
  root.setProperty('--composer-dock-h', `${Math.max(0, Math.round(top ? stripH.value : total))}px`)
  root.setProperty('--composer-dock-top-h', `${top ? Math.round(px) : 0}px`)
}
watch(stripH, () => setDockHeight(dockPx))
watch(phonePos, () => setDockHeight(dockPx))
function watchDock(on: boolean) {
  dockObserver?.disconnect()
  dockObserver = null
  const el = formEl.value
  if (!on || !el) {
    setDockHeight(0)
    return
  }
  setDockHeight(el.getBoundingClientRect().height)
  if (typeof ResizeObserver !== 'undefined') {
    dockObserver = new ResizeObserver(() => setDockHeight(el.getBoundingClientRect().height))
    dockObserver.observe(el)
  }
}
watch(docked, (on) => { void nextTick(() => watchDock(on)) })
/* the sheet's Reply (MessageCard) puts the caret here */
function onFocusRequest() {
  inputEl.value?.focus()
}
onMounted(() => {
  emit('ready', { setText })
  watchDock(docked.value)
  window.addEventListener(COMPOSER_FOCUS_EVENT, onFocusRequest)
})
onBeforeUnmount(() => {
  dockObserver?.disconnect()
  if (props.global) setDockHeight(0)
  window.removeEventListener(COMPOSER_FOCUS_EVENT, onFocusRequest)
})
/* A drag on the grip. Null until the reader sets one, then typing does not
   snap the box back. Kept across a collapse so the next focus can reopen it. */
const userHeight = ref<number | null>(null)
/* Last open height when the reader did not drag. Null when it was one line. */
const openHeight = ref<number | null>(null)
/* True after focus leaves, so a tall draft stays one line until the reader
   comes back. Ctrl+Enter does not park: the caret is still in the box. */
const parked = ref(false)
/* Ctrl+Enter collapses while the caret stays. The next key sizes to the new
   text; the saved height waits for the next focus. */
const contentUntilFocus = ref(false)
/* A fit queued by the send that clears the text must not reopen the box. */
let fitSerial = 0
function omniboxMax() {
  /* docked: 40% of what the keyboard leaves, so the page stays in view */
  if (docked.value) return Math.max(36, Math.floor((window.innerHeight - kbInset.value) * 0.4))
  /* topic c6994436: in the bottom dock the box pushes the feed up, not over */
  return omniboxMaxHeight({ innerHeight: window.innerHeight - kbInset.value, bottom: Boolean(props.bottom) })
}
function collapseGlobalBox(park: boolean) {
  const el = inputEl.value
  if (!el || !props.global) return
  openHeight.value = omniboxRememberHeight({
    userHeight: userHeight.value,
    openHeight: openHeight.value,
    measured: Math.round(el.getBoundingClientRect().height),
    keep: parked.value || contentUntilFocus.value,
  })
  parked.value = park
  if (!park) {
    contentUntilFocus.value = true
    const serial = ++fitSerial
    void nextTick(() => {
      if (fitSerial === serial) fitSerial++
    })
  }
  el.style.height = '36px'
}
function onOmniboxFocus() {
  if (!props.global) return
  parked.value = false
  contentUntilFocus.value = false
  const px = omniboxFocusHeight(userHeight.value, openHeight.value, omniboxMax())
  const el = inputEl.value
  if (px != null && el) {
    el.style.height = `${px}px`
    return
  }
  void nextTick(fitGlobalBox)
}
function onOmniboxBlur(ev: FocusEvent) {
  if (!props.global) return
  const next = ev.relatedTarget
  if (next instanceof Element && next.closest('[data-test="omnibox-resize"]')) return
  collapseGlobalBox(true)
}
/* Attach and Send swallow their mousedown (@mousedown.prevent): the focus
   stays in the box, so the blur above does not snap a tall draft to one line
   the moment the reader reaches for Attach (measured 126px -> 36px on the
   mock, 2026-09-25). The click itself fired either way in Chromium. */
/* field-sizing is not enough inside the top-bar flex row: the used height
   stays one line. Measure the text and set the height. Only the field grows.
   The automatic size stops at 40% of the window; the grip can go to the
   bottom of the screen. The bar itself stays 58px (SPL-977). */
function fitGlobalBox() {
  const el = inputEl.value
  if (!el || !props.global || parked.value) return
  if (!contentUntilFocus.value && userHeight.value != null) {
    const px = omniboxFocusHeight(userHeight.value, null, omniboxMax())
    if (px != null) {
      el.style.height = `${px}px`
      return
    }
  }
  /* owner, t1 d3bbe2c2: "I cannot see the last part of the msg WHERE AM I
     typing" / "something with the scroll resets it up" - the 'auto' measure
     drops the field's scroll to the top while a phone keyboard composes
     (measured: scrollTop 0, the caret 441 px under the box). Text that only
     grew needs no collapse; after one, the scroll goes back, and a caret at
     the end stays in view. */
  const cap = Math.min(omniboxMax(), Math.floor(window.innerHeight * 0.4))
  if (el.scrollHeight > el.clientHeight) {
    el.style.height = `${Math.min(el.scrollHeight, cap)}px`
  } else {
    const scrolled = el.scrollTop
    el.style.height = 'auto'
    el.style.height = `${Math.min(el.scrollHeight, cap)}px`
    el.scrollTop = scrolled
  }
  if (document.activeElement === el && el.selectionEnd === el.value.length) el.scrollTop = el.scrollHeight
}
function startResize(ev: PointerEvent) {
  const el = inputEl.value
  const handle = ev.currentTarget
  if (!el || !(handle instanceof HTMLElement)) return
  ev.preventDefault()
  handle.setPointerCapture(ev.pointerId)
  const startY = ev.clientY
  const startH = el.getBoundingClientRect().height
  const move = (e: PointerEvent) => {
    const next = resizeHeight({ startH, startY, y: e.clientY, bottom: Boolean(props.bottom) && !docked.value, max: omniboxMax() })
    userHeight.value = next
    el.style.height = `${next}px`
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
watch(text, () => {
  if (!props.global) return
  const serial = fitSerial
  void nextTick(() => {
    if (serial !== fitSerial) return
    fitGlobalBox()
  })
})
onMounted(() => { fitGlobalBox() })
/* owner, t1 21:53Z: a new phone size (or a place with another size). The
   field's own height was measured under the old floor; measure it again
   under the new one, so a smaller size really shrinks it */
watch(phoneShare, () => {
  void nextTick(() => {
    const el = inputEl.value
    if (!el || !docked.value) return
    if (parked.value) el.style.height = '36px'
    else fitGlobalBox()
  })
})
const fileEl = ref<HTMLInputElement | null>(null)
/* Empty, busy, or with nowhere to send: the button stays in the tab order
   (aria-disabled, not disabled) and onSend refuses the click. */
const cannotSend = computed(() => Boolean(props.busy) || (Boolean(props.sendBlocked) && !docked.value) || (!text.value.trim() && !picked.value.length))
const inQuery = ref<string | null>(null)
const inIdx = ref(0)
const inListEl = ref<HTMLUListElement | null>(null)
/** The topic the reader picked, so two starters with one title stay distinct. */
const pickedIn = ref<{ taskId: string, title: string, channel: string } | null>(null)
const topicsAsked = ref(false)
/** Slack's ``` composer: the caret sits inside an open code block. */
const inCode = ref(false)
/**
 * 013 FR-018 — the send-time size gate. A code block past 3 A4
 * (code-view.mjs SEND_LIMIT: 150 lines / 9000 chars) is a file, not a
 * message: the send is refused here and the author is told to attach it
 * instead. Held as { key, params } so the 19 catalogues own the wording.
 */
const sizeError = ref<ReturnType<typeof sendLimitError>>(null)
const hintId = useId()
const slashHintId = useId()
const opListId = useId()
const opIdx = ref(0)
const opListEl = ref<HTMLUListElement | null>(null)
/** caret offset, kept in sync so the operator picker follows it */
const caretAt = ref(0)
const opClosed = ref(false)
const searchMode = computed(() => Boolean(props.omnibox || props.global) && omniboxMode(text.value) === 'search')
const opTok = computed(() => (searchMode.value ? operatorTokenAt(text.value, caretAt.value) : null))
const opCandidates = computed(() => (opTok.value ? completeOperators(opTok.value.token, props.operators, roster.peers).slice(0, OP_PICKER_CAP) : []))
const opPickerOpen = computed(() => !opClosed.value && opCandidates.value.length > 0)

/** Same scroll as the mention list: arrows move this dropdown, not the page. */
function scrollActiveOp() {
  nextTick(() => {
    const list = opListEl.value
    if (!list) return
    const row = list.querySelectorAll<HTMLElement>('.mention-item')[opIdx.value]
    if (!row) return
    const listRect = list.getBoundingClientRect()
    const rowRect = row.getBoundingClientRect()
    if (rowRect.top < listRect.top) list.scrollTop += rowRect.top - listRect.top
    else if (rowRect.bottom > listRect.bottom) list.scrollTop += rowRect.bottom - listRect.bottom
  })
}

function onOperatorKey(ev: KeyboardEvent): boolean {
  if (!opPickerOpen.value) return false
  const n = opCandidates.value.length
  if (ev.key === 'ArrowDown') {
    ev.preventDefault()
    opIdx.value = (opIdx.value + 1) % n
    scrollActiveOp()
    return true
  }
  if (ev.key === 'ArrowUp') {
    ev.preventDefault()
    opIdx.value = (opIdx.value - 1 + n) % n
    scrollActiveOp()
    return true
  }
  if (ev.key === 'Tab' || (ev.key === 'Enter' && !ev.shiftKey)) {
    ev.preventDefault()
    const c = opCandidates.value[opIdx.value]
    if (c) pickOp(c.insert)
    return true
  }
  if (ev.key === 'Escape') {
    ev.preventDefault()
    opClosed.value = true
    return true
  }
  return false
}

function pickOp(insert: string) {
  const tok = opTok.value
  if (!tok) return
  const next = applyCompletion(text.value, tok, insert)
  text.value = next.text
  caretAt.value = next.cursor
  opIdx.value = 0
  nextTick(() => {
    const el = inputEl.value
    if (!el) return
    el.focus()
    el.setSelectionRange(next.cursor, next.cursor)
  })
}

/** 022: the top bar sets the line (deep link ?q=, mobile expand) */
function setText(s: string) {
  text.value = s
  nextTick(() => {
    const el = inputEl.value
    if (!el) return
    /* c6994436: set while TopBar's deferred Teleport is still mounting this
       box, the text never reaches the field (measured: text set, field
       empty) - the field follows the text here */
    if (el.value !== s) el.value = s
    caretAt.value = s.length
    el.setSelectionRange(s.length, s.length)
  })
}
function focusInput() {
  inputEl.value?.focus()
}
/* the box is cleared on emit, because the emit is fire-and-forget
   and there is nothing to await. That is fine as long as a caller whose send
   FAILED can put the text back - otherwise the only copy of what the human
   wrote is gone, which is exactly how the owner lost a message. */
function restore(body: string, files?: File[]) {
  text.value = mp.decode(body)
  if (files && files.length) picked.value = [...files]
  focusInput()
}
/* SPL-13: the top bar calls this when the route leaves /search */
function leaveSearch() {
  const next = omniboxTextLeavingSearch(text.value)
  if (next !== text.value) text.value = next
}
defineExpose({ setText, focus: focusInput, restore, leaveSearch })

const { t, te } = useI18n({ useScope: 'global' })
/* SPL-976: Enter follows Settings -> Behaviour -> "Text fields" */
const { keyAction, mode: submitMode, hintFor } = useSubmitKey()
const syntaxOpen = ref(false)
const syntaxId = useId()
const fieldEl = ref<HTMLElement | null>(null)
/* 085 FR-005: one row per key hint, in the Enter mode the reader set */
const phoneHints = computed(() => t(hintFor('search.phone_hints')).split(' · ').map((h) => h.trim()).filter(Boolean))
const syntaxRows = computed(() => operatorHelpRows(props.operators && props.operators.length ? props.operators : undefined))
const placeholder = computed(() => props.placeholder || t('composer.placeholder_default', { mention: '@CLE-07' }))
/* HUM-24 (CLE-77879): one mode, one look - the label, its icon, the field's
   accent (data-mode) and the GO button's words all follow dockHint */
const modeText = computed(() => {
  const label = composerModeLabel(dockHint.value)
  return label ? t(label.key, label.params) : ''
})
const intoTree = computed(() => Boolean(dockHint.value && (dockHint.value.mode === 'thread' || dockHint.value.mode === 'comment')))
/* owner, t1 3d6d945d "A": the glyph in the box - a new topic or into the tree;
   a DM, /search and a page with no send target show none.
   HUM-10 (t1 3ffb2dee): on the phone the placeholder is already "#{name}".
   A hash glyph in front of it reads "# #name". Drop the glyph there; the
   gap it opened goes with it. Desktop keeps the glyph: its placeholder
   is "Message #name", which is not the same doubling. */
const modeGlyph = computed<'thread-tree' | 'hash' | null>(() => {
  if (!props.global || searchMode.value || !dockHint.value) return null
  if (intoTree.value) return 'thread-tree'
  if (docked.value && dockHint.value.mode === 'new') return null
  return dockHint.value.mode === 'new' ? 'hash' : null
})
/* a phone page with no send target (/issues list, /events, /settings): GO
   there searches for the text, never nothing - data-mode="search", no accent */
const modeAttr = computed(() => {
  if (!props.global || searchMode.value) return undefined
  if (dockHint.value) return dockHint.value.mode
  return docked.value && props.sendBlocked ? 'search' : undefined
})
const sendKey = computed(() => composerSendKey(searchMode.value ? null : dockHint.value))

/*
 * 080 FR-006 / FR-007: the target chip. chipLabel reads what send reads - the
 * page's dock() and place() (one replyTarget()) and the `in: <title>` the
 * line resolves to - so it cannot name one place while the send goes to
 * another. Top-bar box and phone dock, not in /search. 085 FR-001 / FR-002:
 * on the phone dock phoneChipLabel shows it on focus too and cuts it to 12
 * characters (the dock field is ~108 px of text at 360 px).
 */
const chipFocused = ref(false)
const chipFocus = () => { chipFocused.value = true }
const chipBlur = () => { chipFocused.value = false }
watch(inputEl, (el, old) => {
  old?.removeEventListener('focus', chipFocus)
  old?.removeEventListener('blur', chipBlur)
  if (!el) return
  el.addEventListener('focus', chipFocus)
  el.addEventListener('blur', chipBlur)
  chipFocused.value = typeof document !== 'undefined' && document.activeElement === el
})
const chipWords = (c: { key: string, params: Record<string, string>, text: string }) => (c.key ? t(c.key, c.params) : c.text)
const chipInfo = computed(() => {
  if (!props.global || searchMode.value || props.sendBlocked) return null
  const place = String(omniboxTargets.target?.place?.() ?? '')
  const resolved = /(^|\s)in:/i.test(text.value) ? resolveInClause(text.value, topicCatalogue.value) : null
  const named = resolved && resolved.taskId ? { taskId: resolved.taskId, title: resolved.title } : null
  const id = place.startsWith('t:') ? place.slice(2) : ''
  const title = id ? (topicCatalogue.value.find((r) => r.taskId === id)?.title ?? '') : ''
  const opts = { dock: props.dockTarget, place, text: text.value, named, title }
  if (docked.value) return phoneChipLabel(opts, { focused: chipFocused.value, render: chipWords })
  const c = chipLabel(opts)
  return c ? { ...c, full: chipWords(c), short: chipWords(c) } : null
})
const chip = computed(() => Boolean(chipInfo.value))
const chipText = computed(() => chipInfo.value?.short ?? '')
const chipFull = computed(() => chipInfo.value?.full ?? '')
const chipMode = computed(() => {
  const c = chipInfo.value
  if (!c) return undefined
  if (c.key === 'composer.chip_reply') return 'thread'
  return c.text.startsWith('@') ? 'dm' : 'new'
})
/* the text starts after the chip: its width, live */
const chipEl = ref<HTMLElement | null>(null)
const chipW = ref(0)
let chipObserver: ResizeObserver | null = null
watch(chipEl, (el) => {
  chipObserver?.disconnect()
  chipObserver = null
  if (!el) return
  chipW.value = el.offsetWidth
  if (typeof ResizeObserver === 'undefined') return
  chipObserver = new ResizeObserver(() => { chipW.value = el.offsetWidth })
  chipObserver.observe(el)
})
onBeforeUnmount(() => chipObserver?.disconnect())
/* spec Q3: a chip click opens the target - the channel, the DM or the topic
   (an open pane already shows it, so nothing moves) - and the box keeps the focus */
const chipRoute = useRoute()
const chipLocalePath = useLocalePath()
function openChip() {
  const at = chipInfo.value?.open || ''
  const name = encodeURIComponent(at.slice(at.indexOf(':') + 1))
  if (at.startsWith('t:')) {
    const id = at.slice(2)
    if (chipRoute.query.topic !== id && chipRoute.params.task_id !== id) void navigateTo(chipLocalePath('/t/' + name))
  } else if (at === 'ch:lobby') void navigateTo(chipLocalePath('/lobby'))
  else if (at.startsWith('ch:')) void navigateTo(chipLocalePath('/channel/' + name))
  else if (at.startsWith('dm:')) void navigateTo(chipLocalePath('/dm/' + name))
  inputEl.value?.focus()
}

function caret(): number {
  return inputEl.value?.selectionStart ?? text.value.length
}

/* a refusal is about the text that was there; editing it clears it */
watch(text, () => { sizeError.value = null; syntaxOpen.value = false })

function syncMention(ev?: Event) {
  const prevTok = opTok.value && opTok.value.token
  caretAt.value = caret()
  if (ev && ev.type !== 'keyup' && opTok.value?.token !== prevTok) {
    opClosed.value = false
    opIdx.value = 0
    nextTick(() => {
      if (opListEl.value) opListEl.value.scrollTop = 0
    })
  }
  if (searchMode.value) {
    // a search line is a query: no code block, no @-picker, no topic picker
    inCode.value = false
    mp.close()
    inQuery.value = null
    return
  }
  inCode.value = fenceStateAt(text.value, caret()).inCode
  // no @-autocomplete inside a code block: the text there is literal (mp's `blocked`)
  mp.sync()
  /* `in:` is the topic-title picker. An @ token at the caret wins, same as a code fence. */
  const nextIn = (inCode.value || mp.query !== null) ? null : activeInQuery(text.value, caret())
  if (nextIn !== inQuery.value) {
    inIdx.value = 0
    nextTick(() => {
      if (inListEl.value) inListEl.value.scrollTop = 0
    })
  }
  inQuery.value = nextIn
}

/* SPL-985: @ finds a person or agent by id or by the display name they chose; the tag
   inserted is still the id. The same picker serves every text field. */
const mp = useMentionPicker({ text, el: inputEl, blocked: () => searchMode.value || inCode.value })
const pickerOpen = computed(() => mp.open)

const topicCatalogue = computed(() => topicChoices({
  topics: viewer.topics,
  messages: [...channelFeed.messages, ...liveMain.messages],
}))
const inCandidates = computed(() => (
  inQuery.value === null ? [] : filterTopicTitles(topicCatalogue.value, inQuery.value)
))
const inPickerOpen = computed(() => inQuery.value !== null && inCandidates.value.length > 0 && !pickerOpen.value)

watch(inQuery, (q) => {
  if (q === null || topicsAsked.value || viewer.topics.length > 0) return
  topicsAsked.value = true
  void viewer.loadTopics()
})

function scrollActiveIn() {
  nextTick(() => {
    const list = inListEl.value
    if (!list) return
    const row = list.querySelectorAll<HTMLElement>('.mention-item')[inIdx.value]
    if (!row) return
    const listRect = list.getBoundingClientRect()
    const rowRect = row.getBoundingClientRect()
    if (rowRect.top < listRect.top) list.scrollTop += rowRect.top - listRect.top
    else if (rowRect.bottom > listRect.bottom) list.scrollTop += rowRect.bottom - listRect.bottom
  })
}

function pickIn(row: { taskId: string, title: string, channel: string }) {
  const next = insertInClause(text.value, caret(), row.title)
  text.value = next.text
  pickedIn.value = { taskId: row.taskId, title: row.title, channel: row.channel }
  inQuery.value = null
  nextTick(() => {
    const el = inputEl.value
    if (!el) return
    el.focus()
    el.setSelectionRange(next.cursor, next.cursor)
  })
}

function insertOperator(op: string) {
  syntaxOpen.value = false
  const cur = text.value
  const next = omniboxMode(cur) !== 'search'
    ? `/search ${op}`
    : (() => {
        const at = inputEl.value?.selectionStart ?? cur.length
        const gap = at > 0 && !/\s/.test(cur[at - 1] || '') ? ' ' : ''
        return cur.slice(0, at) + gap + op + cur.slice(at)
      })()
  text.value = next
  nextTick(() => {
    const el = inputEl.value
    if (!el) return
    caretAt.value = next.length
    el.focus()
    el.setSelectionRange(next.length, next.length)
  })
}

/* 085 FR-004: the phone Search button. Search mode is the state `/search `
   sets, so a typed line that was there becomes the query; a second tap clears
   the search line (omniboxTextLeavingSearch) and closes the list */
function onSyntaxButton() {
  if (!docked.value) {
    syntaxOpen.value = !syntaxOpen.value
    return
  }
  if (searchMode.value) {
    syntaxOpen.value = false
    setText(omniboxTextLeavingSearch(text.value))
    return
  }
  setText(text.value.trim() ? `/search ${text.value.trim()}` : '/search ')
  focusInput()
  /* after the text watcher, which closes the list on every edit - and so
     closes it again once the box is emptied (search mode left) */
  void nextTick(() => { syntaxOpen.value = true })
}

function onSyntaxPointerDown(ev: PointerEvent) {
  if (!syntaxOpen.value) return
  const root = fieldEl.value
  if (root && ev.target instanceof Node && root.contains(ev.target)) return
  syntaxOpen.value = false
}

function onKeydown(ev: KeyboardEvent) {
  /* spec 066 M6: keydown -> the next paint (one in ten; a no-op with RUM off) */
  perfKeydown(ev.timeStamp)
  if (ev.isComposing) return
  if (syntaxOpen.value && ev.key === 'Escape') {
    ev.preventDefault()
    syntaxOpen.value = false
    return
  }
  if (onOperatorKey(ev)) return
  if (props.global && onGlobalKey(ev)) return
  if (inCode.value && ev.key === 'Escape' && !pickerOpen.value && !inPickerOpen.value) {
    // Slack's exit: close the block at the caret, keep typing below it
    ev.preventDefault()
    const next = exitFence(text.value, caret())
    text.value = next.text
    inCode.value = false
    nextTick(() => inputEl.value?.setSelectionRange(next.cursor, next.cursor))
    return
  }
  if (props.omnibox && ev.key === 'Escape' && !pickerOpen.value && !inPickerOpen.value) {
    emit('search', '')
    return
  }
  if (mp.onKeydown(ev)) return
  if (inPickerOpen.value) {
    const n = inCandidates.value.length
    if (ev.key === 'ArrowDown') {
      ev.preventDefault()
      inIdx.value = (inIdx.value + 1) % n
      scrollActiveIn()
      return
    }
    if (ev.key === 'ArrowUp') {
      ev.preventDefault()
      inIdx.value = (inIdx.value - 1 + n) % n
      scrollActiveIn()
      return
    }
    if (ev.key === 'Tab' || (ev.key === 'Enter' && !ev.shiftKey)) {
      ev.preventDefault()
      const row = inCandidates.value[inIdx.value]
      if (row) pickIn(row)
      return
    }
    if (ev.key === 'Escape') {
      ev.preventDefault()
      inQuery.value = null
      return
    }
  }
  if (ev.key === 'Enter') {
    const state = fenceStateAt(text.value, caret())
    inCode.value = state.inCode
    if (keyAction(ev, { inCode: state.inCode }) === 'submit') {
      ev.preventDefault()
      onSend()
      collapseGlobalBox(false)
    }
  }
}

/** 022 top-bar keys; true = handled. */
function onGlobalKey(ev: KeyboardEvent): boolean {
  if (searchMode.value) {
    if (ev.key === 'Enter' && !ev.shiftKey && (ev.ctrlKey || ev.metaKey)) {
      ev.preventDefault()
      onSend()
      collapseGlobalBox(false)
      return true
    }
    if (ev.key === 'Enter' && !ev.shiftKey) {
      ev.preventDefault()
      onSend()
      collapseGlobalBox(false)
      return true
    }
    if (ev.key === 'ArrowDown' && caret() === text.value.length) {
      ev.preventDefault()
      emit('results')
      return true
    }
  }
  if (ev.key === 'Escape' && !inCode.value && !pickerOpen.value && !inPickerOpen.value) {
    ev.preventDefault()
    if (text.value) text.value = ''
    else emit('dismiss')
    return true
  }
  return false
}

function onSend() {
  /* `/switch-pane: messages|channels|topics|flow` changes the left pane
     and is never sent. `topic` is the same pane. An unknown name stays in the box. */
  if (props.global || props.omnibox) {
    const pane = switchPaneOf(text.value)
    if (pane !== null) {
      if (pane) {
        useSidePane().request(pane)
        text.value = ''
        picked.value = []
        mp.close()
        inQuery.value = null
      }
      return
    }
  }
  if (props.global && searchMode.value) {
    // the rest of the line goes to the hub verbatim (search-v1 §0)
    emit('search', searchQueryOf(text.value))
    opClosed.value = true
    return
  }
  if (props.global && props.sendBlocked) {
    /* (owner: "clicking the GO button does not create a comment"):
       on a phone GO is the only button, so with no send target the text is
       a search rather than a tap that does nothing. Desktop is unchanged. */
    const q = text.value.trim()
    if (docked.value && q) {
      emit('search', q)
      text.value = ''
    }
    return
  }
  /* Enter and the Send button both land here. An open title list picks;
     it does not send the half-typed `in:`. */
  if (inPickerOpen.value) {
    const row = inCandidates.value[inIdx.value]
    if (row) pickIn(row)
    return
  }
  if (props.omnibox && !props.global) {
    const parsed = parseOmnibox(text.value)
    if ('search' in parsed) {
      emit('search', parsed.search || '')
      text.value = ''
      return
    }
  }
  /* SPL-1009: the field shows picked people by name; the message stores their tags */
  let body = closeOpenFence(mp.encode(text.value)).trim()
  let topicId = props.parentTaskId
  let channelId: string | undefined
  if ((props.global || props.omnibox) && body) {
    const resolved = resolveInClause(body, topicCatalogue.value)
    if (resolved.taskId) {
      const chosen = pickedIn.value
      const same = Boolean(chosen && resolved.title.toLowerCase() === chosen.title.toLowerCase())
      body = resolved.body
      topicId = same && chosen ? chosen.taskId : resolved.taskId
      channelId = (same && chosen ? chosen.channel : resolved.channel) || undefined
    }
  }
  if ((!body && !picked.value.length) || props.busy) return
  const tooBig = sendLimitError(body)
  if (tooBig) {
    // nothing is sent and nothing is cleared: the author keeps the text and
    // can attach it as a file (005 T023 upload) instead
    sizeError.value = tooBig
    return
  }
  /* spec 066 M3 starts here; LiveFeed ends it when the row is confirmed */
  perfSendStart()
  emit('send', body, topicId, picked.value.slice(), channelId)
  text.value = ''
  picked.value = []
  mp.close()
  inQuery.value = null
  pickedIn.value = null
  inCode.value = false
}

/* Owner, 2026-09-25: eight tries, eight messages with no file, and not a
   word on screen. A DOUBLE-CLICK on the file in the GTK file dialog lost the
   pick before the page saw it (Select + Open worked, n=1). The page cannot
   get that file back, but it must not stay silent: when the dialog closes
   with nothing, say so and name the two ways that work. Chrome fires
   `cancel` on the input for an empty close; a close that fires neither
   `change` nor `cancel` is caught when the window gets the focus back. */
const pickLost = ref(false)
/* e3e9ca61: the phone's top notice closes itself after this long */
const ATTACH_NOTICE_MS = 8000
let awaitingPick = false
let pickTimer: ReturnType<typeof setTimeout> | null = null

function clearPickWait() {
  awaitingPick = false
  if (pickTimer) clearTimeout(pickTimer)
  pickTimer = null
  window.removeEventListener('focus', onWindowFocusAfterPick)
}

function onWindowFocusAfterPick() {
  if (!awaitingPick) return
  if (pickTimer) clearTimeout(pickTimer)
  pickTimer = setTimeout(() => {
    if (awaitingPick) pickLost.value = true
    clearPickWait()
  }, 1000)
}

function openFiles() {
  pickLost.value = false
  clearPickWait()
  awaitingPick = true
  window.addEventListener('focus', onWindowFocusAfterPick)
  fileEl.value?.click()
}

function onPickCancel() {
  clearPickWait()
  pickLost.value = true
}

function onFiles(ev: Event) {
  clearPickWait()
  const input = ev.target as HTMLInputElement
  if (!input.files || input.files.length === 0) {
    pickLost.value = true
    return
  }
  pickLost.value = false
  // uploaded on send (POST /v1/files), then referenced by file_id in files[]
  picked.value = [...picked.value, ...input.files]
  input.value = ''
}
onBeforeUnmount(clearPickWait)

/* e3e9ca61 (owner, on a phone): "whenever I click somewhere else, the snack
   bar and the omnibar should disappear". Attach keeps the focus in the box
   (@mousedown.prevent), so after the picker the box is still open at 40% of
   the screen with the keyboard up. A tap outside the dock now blurs it, which
   collapses it (onOmniboxBlur) and drops the keyboard. Desktop: unchanged. */
let offDockOutside: (() => void) | null = null
function onDockOutside() {
  const el = inputEl.value
  if (el && document.activeElement === el) el.blur()
}
watch(docked, (on) => {
  offDockOutside?.()
  offDockOutside = on && typeof document !== 'undefined' ? onOutsideTap(document, () => [formEl.value], onDockOutside) : null
}, { immediate: true, flush: 'post' })
onBeforeUnmount(() => { offDockOutside?.() })

/* A pasted screenshot or copied file is attached, as if picked with Attach.
   A paste with no files, or rich text from a document, stays a text paste. */
function onPaste(ev: ClipboardEvent) {
  if (!pasteAttaches(ev.clipboardData)) return
  ev.preventDefault()
  pickLost.value = false
  picked.value = [...picked.value, ...filesOf(ev.clipboardData)]
}

/* A file dropped anywhere on the page is attached to the Omnibox. Without
   this the browser opens the dropped file and leaves the app. Only the one
   global Omnibox listens, so a drop is attached once. */
function onWindowDragOver(ev: DragEvent) {
  if (!carriesFiles(ev.dataTransfer)) return
  ev.preventDefault()
  if (ev.dataTransfer) ev.dataTransfer.dropEffect = 'copy'
}

function onWindowDrop(ev: DragEvent) {
  if (!carriesFiles(ev.dataTransfer)) return
  ev.preventDefault()
  const files = filesOf(ev.dataTransfer)
  if (!files.length) return
  pickLost.value = false
  picked.value = [...picked.value, ...files]
  focusInput()
}

onMounted(() => {
  if (!props.global) return
  window.addEventListener('dragover', onWindowDragOver)
  window.addEventListener('drop', onWindowDrop)
  window.addEventListener('pointerdown', onSyntaxPointerDown)
})
onBeforeUnmount(() => {
  window.removeEventListener('dragover', onWindowDragOver)
  window.removeEventListener('drop', onWindowDrop)
  window.removeEventListener('pointerdown', onSyntaxPointerDown)
})
</script>

<style scoped>
.composer-too-big {
  display: flex;
  align-items: flex-start;
  gap: 6px;
  margin: 0 0 6px;
  padding: 6px 8px;
  border: 1px solid var(--color-danger);
  border-radius: var(--radius);
  background: var(--color-bg-2);
  color: var(--color-danger);
  font-size: 0.75rem;
  max-width: 100%;
  min-width: 0;
  overflow-wrap: anywhere;
}
.composer-too-big span { min-width: 0; }
/* Owner, t1 5b75590c: "some kind of strange vertical black line in the Omni
   box on mobile" - the default caret, a solid text-colour bar. It takes the
   focused field's ring colour instead, so it reads as the cursor (light and
   dark: the token is per theme; tests/e2e/omnibox-caret-color.test.mjs). */
textarea { caret-color: var(--focus-ring); }
textarea.in-code {
  font-family: var(--font-mono);
  font-size: 0.8125rem;
  background: var(--color-bg-2);
}
/* kept in the tree while empty so the live region announces entering a block */
.code-hint {
  margin: 0;
  font-size: 0.6875rem;
  overflow-wrap: anywhere;
}
.file-chips {
  list-style: none;
  margin: 0 0 6px;
  padding: 0;
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  max-width: 100%;
  min-width: 0;
}
.file-kind-icon {
  vertical-align: middle;
  margin-right: 4px;
  color: var(--color-muted);
}
.file-kind-icon[data-kind="pdf"] { color: #d93025; }
.file-kind-icon[data-kind="doc"] { color: #2b6cd4; }
.file-kind-icon[data-kind="sheet"] { color: #1e8e3e; }
.file-kind-icon[data-kind="slides"] { color: #e8710a; }
.file-chip-thumb {
  display: inline-block;
  vertical-align: middle;
  width: 32px;
  height: 32px;
  object-fit: contain;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: repeating-conic-gradient(var(--color-bg-2) 0 25%, var(--color-surface) 0 50%) 0 0 / 8px 8px;
  margin-right: 4px;
}
.file-chips li {
  font-size: 0.75rem;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  padding: 2px 6px;
  overflow-wrap: anywhere;
  min-width: 0;
}
.attach,
.dock-back {
  cursor: pointer;
  background: transparent;
  color: var(--color-muted);
  border: 0;
  font-weight: 400;
  box-shadow: none;
  display: inline-flex;
  align-items: center;
  justify-content: center;
}
.composer-send[aria-disabled='true'],
.composer-go:disabled { opacity: 0.45; cursor: not-allowed; }
/* SPL-977: the tooltip, on top of everything, shown on hover and keyboard focus */
.composer-go { position: relative; }
.composer-go__tip {
  position: absolute;
  top: calc(100% + 6px);
  left: 50%;
  transform: translateX(-50%);
  z-index: var(--z-modal);
  padding: 4px 8px;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  color: var(--color-fg);
  font-size: 0.75rem;
  font-weight: 600;
  white-space: nowrap;
  pointer-events: none;
  visibility: hidden;
  opacity: 0;
}
.composer-go:hover .composer-go__tip,
.composer-go:focus-visible .composer-go__tip { visibility: visible; opacity: 1; }
.mention-list {
  list-style: none;
  margin: 0 0 8px;
  padding: 4px 0;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  max-height: 180px;
  min-height: 0;
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior: contain;
  max-width: 100%;
  min-width: 0;
}
.mention-list li {
  margin: 0;
  padding: 0;
  max-width: 100%;
  min-width: 0;
}
.mention-item {
  border-radius: var(--radius-sm);
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
  max-width: 100%;
  min-width: 0;
  min-height: var(--tap);
  padding: 6px 10px;
  background: transparent;
  border: 0;
  color: var(--color-fg);
  cursor: pointer;
  text-align: left;
  font-size: 0.8125rem;
  box-sizing: border-box;
}
.mention-item:hover {
  background: var(--color-surface-hover);
}
/* the highlighted suggestion is a SELECTED list row — darker fill,
   one 3px marker bar in the shared ring colour. */
.mention-item.active {
  background: var(--color-selected);
  box-shadow: inset var(--select-bar-w) 0 0 var(--focus-ring);
}
.mention-label {
  min-width: 0;
  overflow-wrap: anywhere;
}
.omnibox-mode {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  font-size: 0.6875rem;
  padding: 1px 8px;
  margin: 0 0 4px;
  border-radius: var(--radius-pill);
  background: var(--color-accent);
  color: var(--color-on-accent);
  max-width: 100%;
}
.op-list code { font-family: var(--font-mono); }
.op-example {
  font-size: 0.75rem;
  min-width: 0;
  overflow-wrap: anywhere;
}
/* 022: in the top bar the pickers drop DOWN over the page, not up into the bar */
.omnibox--global .composer-box { position: relative; }
.omnibox--global .mention-list {
  position: absolute;
  top: 100%;
  inset-inline: 0;
  margin: 4px 0 0;
  z-index: 60;
  box-shadow: 0 8px 24px rgb(0 0 0 / .25);
}
.search-syntax-btn {
  position: absolute;
  z-index: 2;
  top: 6px;
  inset-inline-end: 4px;
  width: 22px;
  height: 22px;
  padding: 0;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-sm);
  background: var(--color-surface);
  color: var(--color-muted);
  font: inherit;
  line-height: 1;
  cursor: pointer;
}
.search-syntax {
  position: absolute;
  z-index: 70;
  top: calc(100% + 4px);
  inset-inline: 0;
  max-height: min(50vh, 320px);
  overflow: auto;
  margin: 0;
  padding: 8px 10px;
  background: var(--color-surface);
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  box-shadow: 0 8px 24px rgb(0 0 0 / .25);
}
.search-syntax p { margin: 0 0 8px; overflow-wrap: anywhere; }
.search-syntax__label {
  font-size: 0.6875rem;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.search-syntax ul { list-style: none; margin: 0; padding: 0; }
.search-syntax .search-syntax__keys { margin: 0 0 8px; padding-bottom: 6px; border-bottom: 1px solid var(--color-border); }
.search-syntax__keys li { padding: 2px 0; overflow-wrap: anywhere; }
.search-syntax__op {
  display: flex;
  flex-wrap: wrap;
  gap: 6px 10px;
  width: 100%;
  min-width: 0;
  padding: 4px 2px;
  border: 0;
  background: transparent;
  color: inherit;
  font: inherit;
  text-align: start;
  cursor: pointer;
}
.search-syntax__op code { font-family: var(--font-mono); }
.search-syntax__op span { min-width: 0; overflow-wrap: anywhere; }
/*
 * Topic c6994436 (lane B) — the bottom dock above 820 px (see `bottom`).
 * The box sits at the foot of the middle pane, so everything that dropped
 * DOWN from the top bar opens UP over the feed: the @ list, the `in:`
 * titles, the /search operators and syntax help, and the GO tooltip. The
 * grip's lane moves to the field's top edge (resizeHeight: drag up = taller).
 */
.omnibox--bottom.omnibox--global .mention-list {
  top: auto;
  bottom: 100%;
  margin: 0 0 4px;
  box-shadow: 0 -8px 24px rgb(0 0 0 / .25);
}
.omnibox--bottom .search-syntax {
  top: auto;
  bottom: calc(100% + 4px);
  box-shadow: 0 -8px 24px rgb(0 0 0 / .25);
}
.omnibox--bottom .composer-go__tip {
  top: auto;
  bottom: calc(100% + 6px);
}
.omnibox--bottom.omnibox--global .omnibox-field { padding: 10px 8px 0; }
.omnibox--bottom.omnibox--global .omnibox-resize { top: 1px; bottom: auto; }
.omnibox--bottom.omnibox--global .search-syntax-btn { top: 16px; }
/*
 * HUM-24 (CLE-77879): "creating a new topic must look different from writing
 * a reply". The box keeps its ONE ordinary border in every mode (owner, t1
 * 76b356b2: "some kind of double bordering ... Remove the lilac one" - the
 * coloured start edge is gone); the mode is the placeholder ("Message #x"
 * vs "Reply"), the reply arrow left of the box and the GO words. No chip and
 * no line over the box (t1 7d777e79 / dd98f8d7 / be8fed75).
 */
.composer[data-mode=thread],
.composer[data-mode=comment] { --composer-mode: var(--color-mode-reply); }
/* owner, t1 3d6d945d "A": the glyph sits in the field's start corner, centred
   on the first text line (as the "?" sits in the end corner); the text starts
   after it. Muted for a new topic, the reply colour into the tree. */
.composer-mode-glyph {
  position: absolute;
  z-index: 1;
  top: 10px;
  inset-inline-start: 8px;
  display: inline-flex;
  color: var(--color-muted);
  pointer-events: none;
}
.composer-mode-glyph[data-glyph=thread-tree] { color: var(--color-mode-reply, var(--color-accent)); }
.composer.omnibox--global .has-mode-glyph textarea { padding-inline-start: 24px; }
.omnibox--bottom.omnibox--global .composer-mode-glyph { top: 20px; }
/* 080 FR-006: the target chip sits in the start corner after the glyph, on
   the first text line; the text starts after it (--chip-w, measured) */
.composer-target-chip {
  position: absolute;
  z-index: 1;
  top: 9px;
  inset-inline-start: 8px;
  max-width: 40%;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  padding: 1px 8px;
  border: 1px solid var(--color-border);
  border-radius: var(--radius-pill);
  background: var(--color-surface-hover);
  color: var(--color-muted);
  font: inherit;
  font-size: 0.8125rem;
  line-height: 1.3;
  cursor: pointer;
}
.composer-target-chip[data-mode=thread] { color: var(--color-mode-reply, var(--color-accent)); }
.composer-target-chip:hover { color: var(--color-fg); }
.has-mode-glyph .composer-target-chip { inset-inline-start: 28px; }
.composer.omnibox--global .has-target-chip textarea { padding-inline-start: calc(var(--chip-w, 0px) + 6px); }
.composer.omnibox--global .has-mode-glyph.has-target-chip textarea { padding-inline-start: calc(var(--chip-w, 0px) + 26px); }
.omnibox--bottom.omnibox--global .composer-target-chip { top: 19px; }
/* owner, t1 932eeefc (2026-10-03): Attach + GO stay at the RIGHT end of the
   bottom bar, "just a bit 2 mm on the left to align with the scroll till
   bottom button": 8 px (~2 mm) further in, so on a phone GO's right edge
   lines up with the thread's round scroll-to-bottom arrow (LiveFeed
   .thread-jump, 16 px from the edge; the dock's own padding is 8 px). The
   desktop bottom dock takes the same 8 px. The top positions keep theirs. */
.omnibox--bottom .composer-row { margin-inline-end: 8px; }
/*
 * SPL-991 — the phone dock (see `docked`). The doubled .composer beats
 * main.css's `.composer.omnibox--global ...` rules without !important.
 * 16px text at least: iOS Safari zooms the page into any smaller field on
 * focus; above that it follows the font-size setting (rem).
 * The pickers (@ list, `in:` titles, /search operators) open UPWARD over
 * the page as a full-width sheet, with the keyboard still below the box.
 */
@media (max-width: 820px) {
  .composer.composer--dock.composer--dock {
    position: fixed;
    inset-inline: 0;
    /* CLE-77888: on top of the bottom status strip (0 while the keyboard is up) */
    bottom: calc(var(--kb-inset, 0px) + var(--status-strip-h, 0px));
    z-index: calc(var(--z-sticky, 40) + 10);
    box-sizing: border-box;
    width: 100%;
    max-width: 100%;
    margin: 0;
    padding: 6px 8px calc(6px + env(safe-area-inset-bottom, 0px));
    background: var(--color-sidebar);
    border-top: 1px solid var(--color-border);
    /* CLE-77888 (owner, t1 be8fed75): "a little bit more 3D, as if it were
       on top of the sliding below content" - the house raise (--focus-3d: a
       blurred drop shadow, zero spread) turned upward, over the feed, and a
       1 px top light on the bar's edge; a dark theme cannot show a shadow
       on near-black, so the bar's face also lightens toward its top edge */
    background-image: linear-gradient(180deg, rgba(255, 255, 255, 0.06), rgba(255, 255, 255, 0) 60%);
    box-shadow: 0 -4px 12px rgba(0, 0, 0, 0.32), inset 0 1px 0 rgba(255, 255, 255, 0.14);
  }
  /* the strip under it carries the home-indicator inset */
  :global(html[data-status-strip]) .composer.composer--dock.composer--dock { padding-bottom: 6px; }
  /* SPL-1005: on every page now - a page sheet, dialog or menu is modal over
     it. The dock sits in the top bar's stacking context (z 40), above the
     pages' own sheets (z 38/39), so it steps out of sight while one is open
     (its height stays, so nothing under it moves) */
  .composer.composer--dock.composer--dock[data-yield=true] { visibility: hidden; }
  .composer--dock.composer--dock .composer-box { align-items: flex-end; gap: 4px; }
  .composer--dock.composer--dock .omnibox-field { padding: 0 8px; min-height: var(--tap); }
  .composer--dock.composer--dock .composer-mode-glyph { top: 14px; }
  /* 085 FR-001 / FR-002: 080's chip inside the docked field, right after the
     glyph, on the first line only - the textarea indents line 1 by the chip's
     width (text-indent), wrapped lines take the full width. A 14 px pill of
     at most 12 characters (phoneChipLabel); never a line over the box (owner,
     t1 dd98f8d7) */
  .composer--dock.composer--dock .composer-target-chip {
    top: 11px;
    inset-inline-start: 8px;
    max-width: calc(100% - 16px - var(--tap));
    font-size: 0.875rem;
  }
  .composer--dock.composer--dock .has-mode-glyph .composer-target-chip { inset-inline-start: 32px; }
  .composer.composer--dock.composer--dock .has-target-chip textarea {
    padding-inline-start: 0;
    text-indent: calc(var(--chip-w, 0px) + 6px);
  }
  .composer.composer--dock.composer--dock .has-mode-glyph.has-target-chip textarea { padding-inline-start: 24px; }
  .composer--dock.composer--dock textarea {
    font-size: max(16px, 1rem);
    min-height: var(--tap);
    padding: 10px 0;
    padding-inline-end: var(--tap);
  }
  /* 085 FR-004: the Search button (magnifier), a 44 px target in the
     field's end corner; lit while the box is in search mode */
  .composer--dock.composer--dock .search-syntax-btn {
    top: 0;
    inset-inline-end: 0;
    display: inline-grid;
    place-items: center;
    width: var(--tap);
    height: var(--tap);
    border: 0;
    background: transparent;
  }
  .composer--dock.composer--dock .search-syntax-btn[aria-pressed=true] { color: var(--color-accent); }
  /* one line of hint: the long key wording must not wrap under the box */
  .composer--dock.composer--dock textarea::placeholder {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
  .composer--dock.composer--dock .omnibox-resize,
  .composer--dock.composer--dock .composer-go__tip { display: none; }
  .composer--dock.composer--dock .composer-row { align-self: flex-end; gap: 2px; }
  .composer--dock.composer--dock:not([data-phone-pos=top]) .composer-row { margin-inline-end: 8px; }
  .composer--dock.composer--dock .composer-row button,
  .composer--dock.composer--dock .composer-row .composer-go {
    width: var(--tap);
    height: var(--tap);
    min-width: var(--tap);
    min-height: var(--tap);
    padding: 0;
    margin: 0;
  }
  /* SPL-1005: the bottom-right Send IS the GO - the retired floating
     button's look: a round accent button with the go (play) icon */
  .composer--dock.composer--dock .composer-row .composer-go {
    border: 0;
    border-radius: 50%;
    background: var(--color-accent);
    color: var(--color-on-accent);
    box-shadow: 0 2px 8px rgb(0 0 0 / .3);
  }
  .composer--dock.composer--dock .composer-row .composer-go[aria-disabled=true],
  .composer--dock.composer--dock .composer-row .composer-go:disabled { opacity: .55; }
  .composer--dock.composer--dock .dock-back:disabled { opacity: .35; cursor: default; }
  :global([dir="rtl"]) .dock-back__glyph { transform: scaleX(-1); }
  .composer--dock.composer--dock .file-chips li { display: inline-flex; align-items: center; gap: 4px; }
  .composer--dock.composer--dock .file-chips .icon-btn { width: var(--tap); height: var(--tap); min-width: var(--tap); min-height: var(--tap); }
  .composer--dock.composer--dock .mention-list {
    position: absolute;
    top: auto;
    bottom: 100%;
    inset-inline: 0;
    margin: 0 0 6px;
    max-height: min(40vh, calc((100dvh - var(--kb-inset, 0px)) * 0.45));
    border-radius: var(--radius-lg) var(--radius-lg) 0 0;
  }
  .composer--dock.composer--dock .search-syntax {
    top: auto;
    bottom: calc(100% + 4px);
  }
  .composer.composer--dock.composer--dock[data-dragging=true] {
    opacity: .9;
    transition: none;
  }
  /* TOP: full width right under the top bar (its height carries the notch
     inset). The panes start under it (main.css --composer-dock-top-h). The
     error snackbars (z 60) still slide in over it, above the top bar's
     stacking context (z 40) that this box lives in. */
  .composer.composer--dock.composer--dock[data-phone-pos=top] {
    top: var(--top-bar-h);
    bottom: auto;
    padding: 6px calc(8px + env(safe-area-inset-right, 0px)) 6px calc(8px + env(safe-area-inset-left, 0px));
    border-top: 0;
    border-bottom: 1px solid var(--color-border);
    background-image: linear-gradient(0deg, rgba(255, 255, 255, 0.06), rgba(255, 255, 255, 0) 60%);
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.32), inset 0 -1px 0 rgba(255, 255, 255, 0.14);
  }
  /* there the pickers open DOWNWARD over the page */
  .composer--dock.composer--dock[data-phone-pos=top] .mention-list {
    top: 100%;
    bottom: auto;
    margin: 6px 0 0;
    border-radius: var(--radius-lg);
  }
  .composer--dock.composer--dock[data-phone-pos=top] .search-syntax {
    top: calc(100% + 4px);
    bottom: auto;
  }
  /* RIGHT: the bottom-right corner, 84% of the width (360 px at most), so the
     holding hand's thumb reaches field, Attach and Send and the feed's left
     edge stays readable; physical right in every direction (the thumb) */
  .composer.composer--dock.composer--dock[data-phone-pos=right] {
    left: auto;
    right: 0;
    width: min(84vw, 360px);
    padding-right: calc(8px + env(safe-area-inset-right, 0px));
    border-left: 1px solid var(--color-border);
    border-top-left-radius: var(--radius-lg);
  }
  /* owner, t1 21:53Z: "it should be possible to resize it" - the size the
     grip's size handle or its menu chose (utils/omnibox-dock.mjs). The same
     bounds as there, again here, so a size kept on a bigger screen still
     fits: the field at most half the room under the top bar above the
     keyboard (it stays that size when the focus leaves); in the corner at
     least 280 px and at most the width less 48 px of the feed */
  .composer--dock.composer--dock[data-phone-size=set] textarea {
    min-height: max(var(--tap), calc((100dvh - var(--kb-inset, 0px) - var(--top-bar-h)) * min(var(--dock-field-share, 0), 0.5)));
  }
  .composer.composer--dock.composer--dock[data-phone-pos=right][data-phone-size=set] {
    width: clamp(min(280px, 100vw - 48px), calc(100vw * var(--dock-width-share, 0.84)), calc(100vw - 48px));
  }
}
</style>
