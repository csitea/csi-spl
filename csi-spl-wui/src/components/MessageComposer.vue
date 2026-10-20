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
    :data-docs-hidden="docsHidden ? 'true' : undefined"
    :data-phone-size="docked && phoneShare != null ? 'set' : undefined"
    :style="docked && phoneShare != null ? { [phonePos === 'right' ? '--dock-width-share' : '--dock-field-share']: String(phoneShare) } : undefined"
    @submit.prevent="onSend"
  >
    <!-- owner, t1 2026-10-02: the grip that drags the phone dock to the
         top, the right corner or back to the bottom (OmniboxGrip) -->
    <div v-if="docked" class="lazy-slot" style="display: contents"><OmniboxGrip :box="formEl" /></div>
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
        :class="{ 'has-mode-glyph': modeGlyph, 'has-target-chip': chip, 'is-multiline': multilineLayout, 'has-draft-inline': draftInline }"
        :data-multiline="multilineLayout ? 'true' : undefined"
        :style="chip ? { '--chip-w': chipW + 'px' } : undefined"
        ref="fieldEl"
      >
        <!-- owner, t1 3d6d945d (2026-10-02, option "A"): one glyph inside the
             box at its start says where the post goes. HUM-10: a new topic
             draws no hash glyph, because the name already begins with #.
             The tree (an upside-down F) stays for the open thread or issue.
             Its name is the mode's own words; the placeholder and GO say it too.
             t1 26282b6e: once the draft is more than one line, this prefix
             (display: contents while it is one line) becomes the row above
             the text. -->
        <div v-if="modeGlyph || chip" class="omnibox-prefix">
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
             dd98f8d7). Never on the phone dock (085 FR-001, owner msg b2e7c197:
             "this small control ... should be removed"): the open thread or
             channel names the target there and the text takes the width.
             Replaces the bottom dock's "where it goes" line (c6994436). -->
        <button
          v-if="chip"
          ref="chipEl"
          type="button"
          class="composer-target-chip"
          data-test="composer-target-chip"
          :data-mode="chipMode"
          :title="chipFull"
          @mousedown.prevent
          @click="openChip"
        >{{ chipText }}</button>
        </div>
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
          ref="syntaxBtn"
          v-tap-anim="docked ? 'tilt' : undefined"
          @mousedown.prevent
          @click="onSyntaxClick"
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
        <!-- t1 3558e416: `inline` and ``` blocks look like code while typing.
             Each lazy component behind a v-if sits in an element of its own
             (display: contents, no box): bare, a v-if that flips while its
             chunk loads left Vue's Suspense placeholder outside the field,
             and the patch threw "null (reading 'insertBefore')" - the
             names-not-ids flake (wf 10 run 38552104153), 12 of 12 locally
             with the status-line chunk held 100..600 ms -->
        <div v-if="codeMarksDue" class="lazy-slot" style="display: contents"><LazyComposerCodeMarks :el="inputEl" :text="text" /></div>
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
        <!-- spec 096 §5.1: the DM peer / an @mentioned member is Busy or
             Unavailable - one line, read before sending; loaded on demand -->
        <div v-if="statusLineDue" class="lazy-slot" style="display: contents"><LazyComposerStatusLine :dm-peer="statusDmPeer" :text="text" /></div>
        <!-- SPL-2143: "Draft saved" + Clear while the box holds this place's
             stored draft; loaded on demand, its words in the second catalogue -->
        <div v-if="draft.saved.value && !searchMode" class="lazy-slot" style="display: contents"><LazyComposerDraftState @clear="clearDraftText" /></div>
        <ComposerOpenAsk
          v-if="openAsk.hit"
          :name="openAsk.hit.name"
          @open="openAsk.confirm()"
          @post="openAsk.post()"
          @dismiss="openAsk.dismiss()"
        />
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
          v-tap-anim="'hop'"
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
          v-tap-anim="'wiggle'"
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
          v-tap-anim="'nudge'"
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
import { vTapAnim } from '~/composables/useTapAnim'
import { useChannelStore } from '~/stores/channel'
import { isDocsReadingPath, useOmniboxStore } from '~/stores/omnibox'
import { closeOpenFence, exitFence, fenceStateAt } from '~/utils/code-blocks.mjs'
import { useSubmitKey } from '~/composables/useSubmitKey'
import { sendLimitError } from '~/utils/code-view.mjs'
import { fileKind } from '~/utils/file-preview'
import { useSidePane } from '~/composables/useSidePane'
import { useMentionPicker } from '~/composables/useMentionPicker'
import { useComposerDraft } from '~/composables/useComposerDraft'
import { useComposerDock } from '~/composables/useComposerDock'
import { useComposerSize } from '~/composables/useComposerSize'
import { useComposerPickers } from '~/composables/useComposerPickers'
import { useComposerSyntax } from '~/composables/useComposerSyntax'
import { useComposerFiles } from '~/composables/useComposerFiles'
import { useComposerTarget } from '~/composables/useComposerTarget'
import { COMPOSER_FOCUS_EVENT } from '~/utils/touch-ui.mjs'
import { perfKeydown, perfSendStart } from '~/utils/perf-mark.mjs'
import { parseOmnibox } from '~/utils/feed.mjs'
import { switchPaneOf } from '~/utils/sidebar-tabs.mjs'
import { channelLookupOf, omniboxMode, omniboxTextLeavingSearch, operatorHelpRows, searchQueryOf, type SearchOperator } from '~/utils/search.mjs'
import { resolveInClause } from '~/utils/topic-in.mjs'

/* r13-03: the field's size, the phone dock, the pickers, the "?" button,
   the attachments, the draft and the target chip each live in a
   useComposer* composable; this script wires them to the template, the
   keys and the send */
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
const { t, te } = useI18n({ useScope: 'global' })
const channelFeed = useChannelStore()
const omniboxTargets = useOmniboxStore()
const text = ref('')
const inputEl = ref<HTMLTextAreaElement | null>(null)
const formEl = ref<HTMLFormElement | null>(null)
const fileEl = ref<HTMLInputElement | null>(null)
const chipEl = ref<HTMLElement | null>(null)
const opListEl = ref<HTMLUListElement | null>(null)
const inListEl = ref<HTMLUListElement | null>(null)
const syntaxBtn = ref<HTMLButtonElement | null>(null)
const fieldEl = ref<HTMLElement | null>(null)
/** Slack's ``` composer: the caret sits inside an open code block. */
const inCode = ref(false)
const searchMode = computed(() => Boolean(props.omnibox || props.global) && omniboxMode(text.value) === 'search')
/* the code-marks mirror loads with the first backtick, never for a query */
const codeMarksDue = computed(() => !searchMode.value && text.value.includes('`'))
/* spec 096 §5.1: the DM this box sends to (a reply inside a DM too); the
   line itself (whom it names, @mentions included) loads only once a DM
   peer has a status, or the draft holds an @ while anyone has one */
const statusDmPeer = computed(() => {
  const place = String(omniboxTargets.target?.place?.() ?? '')
  return place.startsWith('dm:') ? place.slice(3) : place.startsWith('t:') ? String(channelFeed.peer || '') : ''
})
/* a DM to a member (HUM-*) or an @ in the draft; the lazy line itself shows
   nothing unless someone named has a status (the composer keeps no status
   state, so its chunks do not depend on the status store - 027 budget) */
const statusLineDue = computed(() => !searchMode.value && (/^HUM-/.test(statusDmPeer.value) || text.value.includes('@')))

const { picked, pickLost, openFiles, onPickCancel, onFiles, onPaste, thumbs } = useComposerFiles({ fileEl, props, focusInput })
const draft = useComposerDraft({ text, props, setText })
/* SPL-2143: off the phone dock, "Draft saved" sits at the field's end, so the
   bar stays one line (composer-mode-cue: <= 50 px). Its room is kept for any
   text this place keeps, not only once saved: typing never re-wraps the text. */
const draftInline = computed(() => draft.keeps.value && !docked.value)
const { docked, phonePos, phoneShare, kbInset, stack } = useComposerDock({ props, formEl, inputEl })
/* phones only: a desktop never loads the grip */
const OmniboxGrip = defineAsyncComponent(() => import('~/components/OmniboxGrip.vue'))
/* SPL-985: @ finds a person or agent by id or by the display name they chose; the tag
   inserted is still the id. The same picker serves every text field. */
const mp = useMentionPicker({ text, el: inputEl, blocked: () => searchMode.value || inCode.value })
const pickerOpen = computed(() => mp.open)
const {
  opIdx, caretAt, opClosed, opCandidates, opPickerOpen, pickOp, onOperatorKey, syncOp,
  inQuery, inIdx, pickedIn, topicCatalogue, inCandidates, inPickerOpen, pickIn, onInKey, syncIn, atCaret,
} = useComposerPickers({ text, inputEl, searchMode, props, mentionOpen: () => pickerOpen.value, opListEl, inListEl })
const { modeText, modeGlyph, modeAttr, sendKey, chip, chipText, chipFull, chipMode, openChip } = useComposerTarget({
  text, inputEl, docked, searchMode, topicCatalogue, t, props,
})
const { collapseGlobalBox, onOmniboxFocus, onOmniboxBlur, startResize, chipW, multilineLayout } = useComposerSize({
  inputEl, text, props, docked, modeGlyph, chip, chipEl, kbInset, phoneShare,
})
const { syntaxOpen, syntaxId, insertOperator, onSyntaxClick } = useComposerSyntax({
  text, inputEl, caretAt, docked, searchMode, props, setText, focusInput, syntaxBtn, fieldEl,
})

/* SPL-2516 (qto reading panel row 02): on a phone's /docs and /workspace/docs
   the dock and the strip under it collapse (height 0: the reading gets the
   73-95 px back). The layout's search button calls openSearch(): the dock
   comes back in search mode, and collapses again once the search line is
   left or the page changes */
const route = useRoute()
const docsHidden = computed(() => docked.value && isDocsReadingPath(route.path) && !omniboxTargets.searchOpen)
watch(() => omniboxTargets.searchAsk, () => {
  if (!searchMode.value) setText(text.value.trim() ? `/search ${text.value.trim()}` : '/search ')
  void nextTick(focusInput)
})
watch(searchMode, (on) => { if (!on) omniboxTargets.closeSearch() })
watch(() => route.path, () => omniboxTargets.closeSearch())

/* the sheet's Reply (MessageCard) puts the caret here. SPL-1637: a poll's
   "Chat about this" hands a start text too (the marker and the question
   quoted); it fills an empty box only, so a draft is never overwritten. */
function onFocusRequest(ev?: Event) {
  const text = (ev as CustomEvent<{ text?: string }> | undefined)?.detail?.text
  if (text && !String(inputEl.value?.value || '').trim()) setText(text)
  inputEl.value?.focus()
}
onMounted(() => {
  emit('ready', { setText })
  window.addEventListener(COMPOSER_FOCUS_EVENT, onFocusRequest)
})
onBeforeUnmount(() => window.removeEventListener(COMPOSER_FOCUS_EVENT, onFocusRequest))
/* Empty, busy, or with nowhere to send: the button stays in the tab order
   (aria-disabled, not disabled) and onSend refuses the click. */
const cannotSend = computed(() => Boolean(props.busy) || (Boolean(props.sendBlocked) && !docked.value) || (!text.value.trim() && !picked.value.length))
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
/* SPL-2143: Clear drops the stored draft and empties the box; the caret stays */
function clearDraftText() {
  draft.clear()
  focusInput()
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

/* SPL-976: Enter follows Settings -> Behaviour -> "Text fields" */
const { keyAction, mode: submitMode, hintFor } = useSubmitKey()
/* 085 FR-005: one row per key hint, in the Enter mode the reader set */
const phoneHints = computed(() => t(hintFor('search.phone_hints')).split(' · ').map((h) => h.trim()).filter(Boolean))
const syntaxRows = computed(() => operatorHelpRows(props.operators && props.operators.length ? props.operators : undefined))
const placeholder = computed(() => props.placeholder || t('composer.placeholder_default', { mention: '@CLE-07' }))

function caret(): number {
  return inputEl.value?.selectionStart ?? text.value.length
}

/* a refusal is about the text that was there; editing it clears it */
watch(text, () => { sizeError.value = null; syntaxOpen.value = false })

function syncMention(ev?: Event) {
  syncOp(ev)
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
  syncIn((inCode.value || mp.query !== null) ? null : atCaret())
}

/* the box a send, a pane switch or an opened channel leaves behind */
function clearBox() {
  text.value = ''
  picked.value = []
  mp.close()
  inQuery.value = null
}

const localePath = useLocalePath()
/* t1 2b15a748 option A. The buttons are ComposerOpenAsk. This hook only
   decides: one visible channel name asks, anything else falls through. */
const openAsk = useOpenChannelAsk({
  text,
  pickedCount: () => picked.value.length,
  channels: () => channelFeed.channels,
  replyOrComment: () => Boolean(props.dockTarget && (props.dockTarget.reply || props.dockTarget.comment)),
  clearAndGo: (id) => {
    clearBox()
    void navigateTo(localePath('/channel/' + encodeURIComponent(id)))
  },
  send: () => onSend(),
})
watch(text, (s) => openAsk.note(s))

function onKeydown(ev: KeyboardEvent) {
  /* spec 066 M6: keydown -> the next paint (one in ten; a no-op with RUM off) */
  perfKeydown(ev.timeStamp)
  if (ev.isComposing) return
  /* the choice is up: Enter opens, Esc keeps the text */
  if (openAsk.onKey(ev)) return
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
  if (mp.onKeydown(ev) || onInKey(ev)) return
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

/** The line is a search, not a post: it has been run (true). */
function searchInstead(): boolean {
  if (props.global && searchMode.value) {
    // the rest of the line goes to the hub verbatim (search-v1 §0)
    emit('search', searchQueryOf(text.value))
    opClosed.value = true
    return true
  }
  /* t1 2b15a748: a # or / word that is not a visible channel still
     searches. A visible one was asked above. A file picked with it is a post. */
  const lookup = (props.global || props.omnibox) && !picked.value.length ? channelLookupOf(text.value) : null
  if (!lookup) return false
  emit('search', lookup)
  text.value = props.global ? `/search ${lookup}` : ''
  return true
}

/** Not a post: a pane switch, an open-channel ask, a search, a pick; true = handled. */
function handledBeforeSend(): boolean {
  /* `/switch-pane: messages|channels|topics|flow` changes the left pane
     and is never sent. `topic` is the same pane. An unknown name stays in the box. */
  const pane = props.global || props.omnibox ? switchPaneOf(text.value) : null
  if (pane !== null) {
    if (pane) {
      useSidePane().request(pane)
      clearBox()
    }
    return true
  }
  if (openAsk.beforeSend() || searchInstead()) return true
  if (props.global && props.sendBlocked) {
    /* (owner: "clicking the GO button does not create a comment"):
       on a phone GO is the only button, so with no send target the text is
       a search rather than a tap that does nothing. Desktop is unchanged. */
    const q = text.value.trim()
    if (docked.value && q) {
      emit('search', q)
      text.value = ''
    }
    return true
  }
  /* Enter and the Send button both land here. An open title list picks;
     it does not send the half-typed `in:`. */
  if (inPickerOpen.value) {
    const row = inCandidates.value[inIdx.value]
    if (row) pickIn(row)
    return true
  }
  if (!props.omnibox || props.global) return false
  const parsed = parseOmnibox(text.value)
  if (!('search' in parsed)) return false
  emit('search', parsed.search || '')
  text.value = ''
  return true
}

/** The post's body and where it goes: an `in: <title>` names the topic. */
function sendTarget() {
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
  return { body, topicId, channelId }
}

function onSend() {
  if (handledBeforeSend()) return
  const { body, topicId, channelId } = sendTarget()
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
  clearBox()
  pickedIn.value = null
  inCode.value = false
}

/* e3e9ca61: the phone's top notice closes itself after this long */
const ATTACH_NOTICE_MS = 8000
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
/* owner, t1 3d6d945d "A": the tree glyph sits in the field's start corner,
   centred on the first text line; the text starts after it, in the reply
   colour. HUM-10: a new topic draws no glyph, so this rule is the reply. */
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
    /* SPL-2093 (owner, t1 04d9c246): "on mobile, the bottom could be a
       little bit smaller" - the dock's controls are 40 px tall (were --tap,
       44; their widths and places stay), still a touch target, and its
       padding 4 px (was 6): 8 px lower */
    --dock-tap: 40px;
    padding: 4px 8px calc(4px + env(safe-area-inset-bottom, 0px));
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
  /* the strip under it carries the home-indicator inset. SPL-2093: and the
     dock keeps a 6 px gap above it (2 px on top instead, so it is still
     51 px): at 4 px the field's bottom edge was 5 px from the strip and
     Chrome's touch adjustment sent a tap there to the version button, whose
     card then opened over the dock. Not :global(html[...]) .composer: Vue
     compiles that to the bare html[...] and drops the rest (it padded <html>) */
  html[data-status-strip] .composer.composer--dock.composer--dock:not([data-phone-pos=top]) { padding-top: 2px; padding-bottom: 6px; }
  /* SPL-1005: on every page now - a page sheet, dialog or menu is modal over
     it. The dock sits in the top bar's stacking context (z 40), above the
     pages' own sheets (z 38/39), so it steps out of sight while one is open
     (its height stays, so nothing under it moves) */
  .composer.composer--dock.composer--dock[data-yield=true] { visibility: hidden; }
  /* SPL-2516: collapsed on the docs routes (docsHidden); the ResizeObserver
     then reports 0, so --composer-dock-h is 0 and the panes pad nothing */
  .composer.composer--dock.composer--dock[data-docs-hidden=true] { display: none; }
  .composer--dock.composer--dock .composer-box { align-items: flex-end; gap: 4px; }
  .composer--dock.composer--dock .omnibox-field { padding: 0 8px; min-height: var(--dock-tap); }
  .composer--dock.composer--dock .composer-mode-glyph { top: 12px; }
  .composer--dock.composer--dock textarea {
    font-size: max(16px, 1rem);
    min-height: var(--dock-tap);
    padding: 8px 0;
    /* t1 e142d4a0: the text area ends where the Search button starts (the
       field's 8 px end padding is under the button too), so no tap on the
       text area is ever under the button */
    width: calc(100% - var(--tap) + 8px);
    /* owner, t1 7ff1521d (msg a980ea90): "there is this strange vertical
       line" - the field's own scrollbar, drawn down the text's end edge
       beside the Search button once a resized or long draft scrolls. A
       finger scrolls the field; the bar is not drawn */
    scrollbar-width: none;
  }
  .composer--dock.composer--dock textarea::-webkit-scrollbar { display: none; }
  /* 085 FR-004: the Search button (magnifier), a 44 px target in the
     field's end corner; lit while the box is in search mode. t1 e142d4a0:
     its square is drawn, so the target is exactly what the eye sees.
     Owner, t1 7ff1521d (msg c9bc359f): "The position of the search button
     seems a bit off and funny when the omnibox is resized" - it was pinned
     to the field's top while Back, Attach and Send sit on the bottom line
     (.composer-box align-items: flex-end); it sits on that line too now.
     One line high, the two places are the same */
  .composer--dock.composer--dock .search-syntax-btn {
    top: auto;
    bottom: 0;
    inset-inline-end: 0;
    display: inline-grid;
    place-items: center;
    width: var(--tap);
    height: var(--dock-tap);
    border: 0;
    background: var(--color-surface-hover);
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
  /* owner, t1 842e581f: "the OmniBox could be 2 mm bigger on the right, but
     the back arrow could be 1 mm on the right, and the other controls should
     stay in the same place" - the row starts on the field's edge (-4 px
     against the box gap) and Back reaches 2 px under Attach (-4 px against
     the row gap): the field is 8 px wider, Back's arrow 4 px further right,
     still a 44 px target, Attach and Send unmoved. Attach is positioned so
     it stays on top of those 2 px even while a disabled Back (opacity) is
     painted as its own layer */
  .composer--dock.composer--dock .composer-row { align-self: flex-end; gap: 2px; margin-inline-start: -4px; }
  .composer--dock.composer--dock .composer-row .dock-back { margin-inline-end: -4px; }
  .composer--dock.composer--dock .composer-row .attach { position: relative; }
  .composer--dock.composer--dock:not([data-phone-pos=top]) .composer-row { margin-inline-end: 8px; }
  .composer--dock.composer--dock .composer-row button,
  .composer--dock.composer--dock .composer-row .composer-go {
    width: var(--tap);
    height: var(--dock-tap);
    min-width: var(--tap);
    min-height: var(--dock-tap);
    padding: 0;
    margin: 0;
  }
  /* SPL-1005: the bottom-right Send IS the GO - the retired floating
     button's look: a round accent button with the go (play) icon */
  .composer--dock.composer--dock .composer-row .composer-go {
    border: 0;
    /* SPL-2093: 44 x 40 now, so round ends rather than an oval */
    border-radius: var(--radius-pill);
    background: var(--color-accent);
    color: var(--color-on-accent);
    box-shadow: 0 2px 8px rgb(0 0 0 / .3);
  }
  .composer--dock.composer--dock .composer-row .composer-go[aria-disabled=true],
  .composer--dock.composer--dock .composer-row .composer-go:disabled { opacity: .55; }
  .composer--dock.composer--dock .dock-back:disabled { opacity: .35; cursor: default; }
  :global([dir="rtl"]) .dock-back__glyph { transform: scaleX(-1); }
  .composer--dock.composer--dock .file-chips li { display: inline-flex; align-items: center; gap: 4px; }
  .composer--dock.composer--dock .file-chips .icon-btn { width: var(--tap); height: var(--dock-tap); min-width: var(--tap); min-height: var(--dock-tap); }
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
    /* SPL-2093: the same 4 px as at the bottom - the dock's ResizeObserver
       sees its content box, so a padding change alone would leave
       --composer-dock-top-h stale */
    padding: 4px calc(8px + env(safe-area-inset-right, 0px)) 4px calc(8px + env(safe-area-inset-left, 0px));
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
     fits: the field at most --dock-field-max, the room up to the top button
     section (owner, t1 8de4c254; useComposerDock measures it at the bottom),
     else half the room under the top bar above the keyboard (it stays that
     size when the focus leaves); in the corner at least 280 px and at most
     the width less 48 px of the feed */
  .composer--dock.composer--dock[data-phone-size=set] textarea {
    min-height: max(var(--dock-tap), min(calc((100dvh - var(--kb-inset, 0px) - var(--top-bar-h)) * min(var(--dock-field-share, 0), 1)), var(--dock-field-max, calc((100dvh - var(--kb-inset, 0px) - var(--top-bar-h)) * 0.5))));
  }
  .composer.composer--dock.composer--dock[data-phone-pos=right][data-phone-size=set] {
    width: clamp(min(280px, 100vw - 48px), calc(100vw * var(--dock-width-share, 0.84)), calc(100vw - 48px));
  }
}
/* One line: the prefix generates no box, so the glyph and the chip stay
   absolutely placed on the first text line (the rules above). More than
   one line (t1 26282b6e): they become a row on top, the text starts at the
   inline start, and 0.25rem (~1 mm at the default font) separates that row
   from the first line. The same rules cover the top bar, the bottom dock
   and the phone dock. */
.omnibox-prefix { display: contents; }
.composer.omnibox--global .omnibox-field.is-multiline {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  row-gap: 0.25rem;
}
.composer.omnibox--global .omnibox-field.is-multiline .omnibox-prefix {
  display: flex;
  flex-direction: row;
  align-items: center;
  gap: 0.25rem;
  min-width: 0;
  max-width: calc(100% - 1.75rem);
  /* the top padding the one-line textarea had: the row keeps the glyph
     where it was, never against the border */
  padding-top: 6px;
}
.composer.omnibox--global .omnibox-field.is-multiline .composer-mode-glyph,
.composer.omnibox--global .omnibox-field.is-multiline .composer-target-chip {
  position: static;
  top: auto;
  inset-inline-start: auto;
  margin: 0;
}
.composer.omnibox--global .omnibox-field.is-multiline .composer-target-chip {
  min-width: 0;
  max-width: 40%;
}
.composer.omnibox--global .omnibox-field.is-multiline textarea,
.composer.composer--dock.composer--dock .omnibox-field.is-multiline textarea {
  width: 100%;
  min-width: 0;
  padding-top: 0;
  padding-inline-start: 0;
  text-indent: 0;
}
@media (max-width: 820px) {
  .composer--dock.composer--dock .omnibox-field.is-multiline .omnibox-prefix {
    max-width: calc(100% - var(--tap));
    padding-top: 8px;
  }
  /* t1 e142d4a0: a multi-line draft keeps clear of the Search button too */
  .composer.composer--dock.composer--dock .omnibox-field.is-multiline textarea { width: calc(100% - var(--tap) + 8px); }
}
/* SPL-2143: the "Draft saved" line inside the field, before the "?" - never
   a second row in the bar. The text keeps clear of it. */
.composer.omnibox--global .omnibox-field.has-draft-inline { --draft-inline-w: 12rem; }
.composer.omnibox--global .omnibox-field.has-draft-inline textarea {
  padding-inline-end: calc(28px + var(--draft-inline-w));
}
.composer.omnibox--global .omnibox-field.has-draft-inline :deep(.composer-draft-state) {
  position: absolute;
  z-index: 2;
  top: 6px;
  inset-inline-end: 30px;
  height: 22px;
  max-width: var(--draft-inline-w);
  margin: 0;
  padding: 0 4px;
  white-space: nowrap;
}
.omnibox--bottom.omnibox--global .omnibox-field.has-draft-inline :deep(.composer-draft-state) { top: 16px; }
</style>
