<template>
  <article
    ref="rowEl"
    class="msg"
    :class="{ selected, 'msg--ai': ai, 'msg--clickable': clickable, 'msg--movable': movable, 'msg--move-over': dropOver, 'msg--dragging': dragging, 'msg--swipe': swipeOn, 'msg--swiping': swipeDx !== 0, 'msg--swipe-armed': swipeArmed, 'msg--swipe-settle': swipeSettle }"
    :style="swipeDx !== 0 ? { '--swipe-dx': `${swipeDx}px`, '--swipe-w': `${Math.abs(swipeDx)}px` } : undefined"
    :data-swipe-archive="swipeArchive ? 'true' : undefined"
    :data-swipe-hide="swipeLeft === 'hide' ? 'true' : undefined"
    :data-swipe-menu="swipeOn ? 'true' : undefined"
    tabindex="0"
    :data-msg-id="msg.msg_id || undefined"
    :data-ts="at || undefined"
    :data-task-id="msg.task_id || undefined"
    :data-opener="msg.is_parent !== 0 ? 'true' : undefined"
    :data-sent="msg.ts || undefined"
    :data-selected="selected ? 'true' : undefined"
    :data-ai="ai ? 'true' : undefined"
    :aria-current="selected ? 'true' : undefined"
    :aria-posinset="posinset || undefined"
    :aria-setsize="setsize || undefined"
    :aria-label="t('feed.card_aria', { who: whoOf(author), kind: kindLabel(String(msg.kind || 'note')) })"
    :aria-describedby="clickable ? 'feed-open-hint' : undefined"
    :data-movable="movable ? 'true' : undefined"
    :data-move-drop="topicMenu ? 'card' : undefined"
    :data-move-id="topicMenu ? (msg.task_id || undefined) : undefined"
    :data-move-ok="topicMenu && move.drag.value ? String(dropTarget) : undefined"
    :data-move-title="dropTarget ? title : undefined"
    :data-last-msg-id="lastMsgId || undefined"
    @click="onClick"
    @dblclick="onDblClick"
    @keydown="onKey"
    @contextmenu="onContextMenu"
    @pointerdown="onRowDown"
    @pointermove="onRowMove"
    @pointerup="onRowUp"
    @pointercancel="onRowCancel"
  >
    <!-- HUM-10 (owner, t1 topic 2d09e9c2): on mobile a swipe LEFT archives
         the topic, a swipe RIGHT opens the card's menu. The strip the card
         uncovers while it slides; armed (past the threshold) it says so.
         HUM-10 (t1 6fc56905): in the topic view a reply's LEFT hides it
         (this device only), so its strip shows the eye-off instead. -->
    <span
      v-if="swipeOn && swipeDx !== 0"
      class="msg-swipe-reveal"
      :class="swipeDir === 'menu' ? 'msg-swipe-reveal--start' : 'msg-swipe-reveal--end'"
      :data-testid="`swipe-${swipeDir}-reveal`"
      :data-armed="swipeArmed ? 'true' : undefined"
      aria-hidden="true"
    >
      <UiIcon :name="swipeDir === 'archive' ? 'archive' : swipeDir === 'hide' ? 'eye-off' : 'menu'" :size="20" />
      <span v-if="swipeArmed && swipeDir !== 'menu'" class="msg-swipe-reveal__text">{{ t(swipeDir === 'hide' ? 'feed.swipe_hide' : 'feed.swipe_archive') }}</span>
    </span>
    <!-- SPL-1134 (specs/045 §3.9): the drag handle, the card's first ~3 mm.
         A move starts from here only; the rest of the card clicks, selects
         and long-presses as before. -->
    <span
      v-if="movable"
      class="msg-move-handle"
      :class="{ 'msg-move-handle--denied': dragging && move.over.value && !move.over.value.ok }"
      data-testid="move-handle"
      :title="canMoveTopic ? t('feed.move.handle_channel') : t('feed.move.handle_topic')"
      aria-hidden="true"
      @pointerdown.stop="onHandleDown"
      @pointermove="handle.move"
      @pointerup="onHandleUp"
      @pointercancel="handle.cancel"
      @lostpointercapture="handle.cancel"
      @click.stop.prevent
      @contextmenu.stop.prevent
    />
    <SpoolAvatar class="avatar" :id="author.id" :box="author.box" />
    <div class="msg-main">
      <!--
        the owner's settled row format, 2026-09-22: per message,
        sender -> recipient, and the arrow flips per row because BOTH ends are
        read from THIS message. A broadcast (ALL-0) has no recipient and shows
        the sender alone. SPL-981 (owner, 2026-09-26): so does a direct
        message (no channel): only the sender's avatar and name.
      -->
      <div class="msg-meta">
        <AgentBadge :id="author.id" :box="author.box || undefined" />
        <!-- HUM-24 (csitea ba4696c1): an AI agent's row says so beside the name -->
        <span
          v-if="ai"
          class="msg-ai-badge"
          data-testid="msg-ai-badge"
          :title="t('feed.ai.title')"
        >{{ t('feed.ai.badge') }}</span>
        <!-- specs/036 FR-011: the human typed this at the agent's terminal -->
        <span
          v-if="author.via"
          class="msg-via-terminal"
          data-testid="msg-typed-by"
          :data-typed-by="author.id"
          :data-via="author.via"
          :title="t('feed.typed_by.title', { who: whoOf(author), agent: author.via })"
        >{{ t('feed.typed_by.badge', { agent: author.via }) }}</span>
        <!-- spec 067 rule 4: a channel copy of a person's DM answer -->
        <span
          v-if="msg.mirror_of"
          class="msg-via-terminal msg-via-dm"
          data-testid="msg-via-dm"
          :data-mirror-of="msg.mirror_of"
          :title="t('feed.via_dm')"
        >{{ t('feed.via_dm') }}</span>
        <template v-if="recipient">
          <span class="msg-to-arrow" aria-hidden="true">→</span>
          <SpoolAvatar class="avatar--to" :id="recipient.id" :box="recipient.box" :size="20" />
          <AgentBadge :id="recipient.id" :box="recipient.box || undefined" />
        </template>
        <KindBadge :kind="String(msg.kind)" :msg="msg" />
        <!-- spec 068 L8: the seat that must deal with it; nothing while nobody is -->
        <span
          v-if="msg.responsible"
          class="msg-responsible"
          data-testid="msg-responsible"
          :data-responsible="msg.responsible"
          :title="t('feed.responsible.title', { seat: msg.responsible })"
        ><span aria-hidden="true">⚑ </span>{{ msg.responsible }}</span>
        <!-- bug B (4ecb4b0d): our own row is drawn the moment Send is pressed;
             until the hub's ack it says so, instead of a time that reads "posted" -->
        <span v-if="msg.pending" class="msg-time msg-time--sending" data-test="msg-sending" role="status" :data-waiting="msg.waiting ? 'network' : undefined">{{ msg.waiting ? t('composer.waiting_network') : t('composer.sending') }}</span>
        <span v-else class="msg-time" :data-test="sinceMs == null ? 'msg-iso-ts' : undefined" :title="timeTitle">{{ time }}</span>
        <!-- SPL-1994 (owner, t1 72898ea2): no agent has answered yet; SPL-2026: from the
             click on Send, never on a send held for the network -->
        <LazyAwaitReply v-if="awaiting && !msg.waiting" :state="awaiting" />
        <span
          v-if="edited"
          class="msg-edited"
          data-test="msg-edited"
          :title="t('feed.edit.marker_title', { at: String(msg.edited_at) })"
        >{{ t('feed.edit.marker') }}</span>
        <!-- spec 080 FR-005: a reply draft waits for this topic -->
        <span
          v-if="hasDraft"
          class="msg-draft"
          data-testid="msg-draft"
          role="img"
          :title="t('composer.draft_mark')"
          :aria-label="t('composer.draft_mark')"
        ><UiIcon name="pencil" :size="12" /></span>
        <!-- Opening messages (is_parent 1) and replies (is_parent 0) are both
             this card. The emoji control is not gated on that flag. -->
        <span class="msg-actions">
          <!-- Tab: the card, then this link, then the menu. The emoji stays
               between them on screen (CSS order) and comes after the menu.
               The Open button paints immediately left of this link (order -1)
               and is reached after the emoji, so this link stays the first stop. -->
          <!-- SPL-982 (owner, topic 8296eeec): exactly "3 >>", no word; the
               name ("3 replies - Open topic") stays on aria-label and title -->
          <!-- CLE-77804 (topic 35053f95): the reader's own unread count before
               the total ("2/7 >>"); a plain total when none are unread ("7 >>"),
               never "0/7". SPL-2422 (owner, t1 89010926): the total counts the
               topic's first message too, which is 1 new for a reader who has not
               seen it ("1/1 >>"); "<new>/<total>" wears the channel row's badge
               (badge-unread), a step smaller and lighter. -->
          <button
            v-if="count > 0 || unreadCount > 0 || alwaysTopic"
            class="replies"
            type="button"
            data-test="topic-replies"
            :data-unread="unreadCount || undefined"
            :data-zero="count === 0 && unreadCount === 0 ? 'true' : undefined"
            :aria-label="repliesName"
            :title="repliesName"
            @click.stop="openReplies"
          >
            <span v-if="unreadCount > 0" class="badge-unread replies__new" data-test="topic-new"><span data-test="topic-unread">{{ unreadCount }}</span>/{{ total }}</span><template v-else>{{ total }}</template> &gt;&gt;
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
          <!-- SPL-1007 (owner, topic 70c82b54): on a phone the chips are half
               size, 3px after this glyph, INSIDE this button - one 44 px
               target that opens the emoji sheet (a pick there adds or
               removes), since two 44 px targets cannot sit 3px apart -->
          <button
            type="button"
            class="icon-btn"
            :class="{ 'msg-emoji-btn--chips': phoneChips }"
            data-testid="msg-emoji-btn"
            :aria-label="phoneChips ? emojiBtnName : t('feed.emoji.add')"
            :title="t('feed.emoji.add')"
            :aria-expanded="pickerOpen ? 'true' : 'false'"
            :disabled="!msg.msg_id || !!msg.pending"
            @click.stop="openPickerFromButton"
          >
            <UiIcon name="smile" :size="16" />
            <span v-if="phoneChips" class="msg-reactions msg-reactions--phone" data-testid="msg-reactions" aria-hidden="true">
              <span
                v-for="chip in chips"
                :key="chip.emoji"
                class="msg-reaction"
                data-testid="msg-reaction"
                :data-emoji="chip.emoji"
                :data-count="chip.count"
                :data-mine="chip.mine ? 'true' : undefined"
                :title="chipTitle(chip)"
              >
                <span>{{ chip.emoji }}</span>
                <span v-if="chip.showCount" class="msg-reaction__n">{{ chip.count }}</span>
              </span>
            </span>
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
             people on, and its tooltip names who reacted.
             CLE-77873 (owner, t1 d6c9661e): the titles view keeps this header
             line and its smile, so it keeps the chips too. Hiding them there
             (an SPL-943 gate from when they were a strip under the body) made
             every pick a silent toggle: added, removed, added, nothing seen. -->
        <span v-if="chips.length && !mobile" class="msg-reactions" data-testid="msg-reactions">
          <button
            v-for="chip in chips"
            :key="chip.emoji"
            type="button"
            class="msg-reaction"
            data-testid="msg-reaction"
            :data-emoji="chip.emoji"
            :data-count="chip.count"
            :data-mine="chip.mine ? 'true' : undefined"
            :aria-label="chip.mine ? t('feed.emoji.mine', { emoji: emojiLabel(chip.emoji) }) : t('feed.emoji.chip', { emoji: emojiLabel(chip.emoji), n: chip.count })"
            :title="chipTitle(chip)"
            :disabled="busy || !msg.msg_id || !!msg.pending"
            @click.stop="onReact(chip.emoji)"
          >
            <span aria-hidden="true">{{ chip.emoji }}</span>
            <span v-if="chip.showCount" class="msg-reaction__n">{{ chip.count }}</span>
          </button>
        </span>
        <span class="msg-meta-spacer" aria-hidden="true" />
      </div>
      <!-- SPL-1024: a card moved to this channel names its home channel, a
           moved reply the topic it came from. Its own line under the author
           row: inside that no-wrap row a narrow pane squeezed it to nothing. -->
      <p
        v-if="movedText"
        class="msg-moved"
        data-testid="msg-moved"
        :data-moved-from="movedFrom"
        :title="movedText"
      >{{ movedText }}</p>
      <!-- spec 067 rule 3: a DM about a channel topic says which, linked to it -->
      <p
        v-if="dmRef"
        class="msg-moved msg-dm-ref"
        data-testid="msg-dm-ref"
        :data-ref-task-id="msg.ref_task_id"
      ><NuxtLink :to="localePath(`/t/${msg.ref_task_id}`)" :title="dmRefTip" @click.stop>{{ dmRefText }}</NuxtLink></p>
      <!-- dc6d5e3f: a channel line between the reader and this DM's agent, shown
           here as a pointer - one stored reply, opened in its topic -->
      <p
        v-if="msg.pointer && msg.channel"
        class="msg-moved msg-dm-ref"
        data-testid="msg-dm-pointer"
        :data-pointer-task-id="msg.task_id"
      ><NuxtLink :to="localePath(`/m/${msg.msg_id}`)" :title="pointerTip" @click.stop>{{ pointerText }}</NuxtLink></p>
      <!--
        the row BECOMES the box ("the msg becomes once again a
        textbox"), pre-filled with the old body. The rendered body is NOT
        replaced while saving and NOT replaced on failure — the new text
        reaches the screen only when the hub's answer arrives and the row
        itself changes underneath us (message-edit-v1 §5).
      -->
      <!--
        (specs/033 FR-020..FR-026): a level-1 card in the middle pane
        takes the pane's height mode. `titles` is the first 90 characters on one
        line; `rows` clips the body and its attachments (pictures and link
        previews too, SPL-2121) at 5 text rows, and a grip under it
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
        :class="{ 'card-clip': clipOn, 'card-clip--cut': clipOn && clipped }"
        :style="clipStyle"
        :data-clip="clipOn ? (clipped ? 'cut' : 'fits') : undefined"
        data-testid="card-body"
      >
        <div ref="clipInner" class="card-body__inner">
          <!-- SPL-985: @ opens the shared picker in the edit box too -->
          <div v-if="editing" class="mention-anchor">
            <!-- HUM-24 (CLE-77879): say it is an edit, not a new post -->
            <p class="msg-edit-mode" data-test="msg-edit-mode"><UiIcon name="pencil" :size="14" /><span>{{ t('feed.edit.mode') }}</span></p>
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
          <MessageBody v-else :body="String(msg.body || '')" :at="msg.ts" no-previews />
          <FileAttachment
            v-for="(f, i) in files"
            :key="String(f.file_id || f.path || i)"
            :file="f"
            :remove="filesRemovable ? () => removeFile(f) : undefined"
          />
          <!-- owner t1 c7ddbf83 ("5 rows should always be 5 rows in size"):
               the cards of the body's internal links sit INSIDE the clip box,
               so the 5-row clip, its fade and its grip count them like text
               (it replaces topic e1f8f797's "under the clip"); titles mode has
               no body, so no preview adds height there -->
          <LinkPreviewsLazy v-if="!editing && linkPreviews.length" :refs="linkPreviews" />
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
      <!-- SPL-2087: a card with no grip keeps the grip's room, so under the
           row cap a 1-row card ends where a cut card's grip ends -->
      <div v-else-if="clipOn" class="card-grip card-grip--room" aria-hidden="true" data-testid="card-grip-room" />
      <p v-if="editing" :id="editHintId" class="muted msg-edit-hint">
        {{ saving ? t('feed.edit.saving') : t('feed.edit.hint') }}
      </p>
      <p v-if="editError" class="msg-edit-error" role="alert" data-test="msg-edit-error">
        <UiIcon name="alert-triangle" :size="14" />
        <span>{{ t(editError) }}</span>
      </p>
      <p v-if="aiError" class="msg-edit-error" role="alert" data-testid="msg-ai-error">
        <UiIcon name="alert-triangle" :size="14" />
        <span>{{ t(aiError) }}</span>
      </p>
      <p v-if="reactError" class="msg-edit-error" role="alert" data-testid="msg-emoji-error">
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
      :parent-kind="parentKind"
      :topic-archive="showTopicArchive"
      :pane-archive="paneArchiveReply"
      :topic-delete="showTopicDelete"
      :kind="kindSettable"
      :move-channel="canMoveTopic"
      :merge-topic="canMoveTopic"
      :move-topic="canMoveMsg"
      :promote-topic="canPromoteMsg"
      :make-issue="canMakeIssue"
      :hide="menuHide"
      :locks="menuLocks"
      :ai-msg="msg"
      :ai-fail="onAiFail"
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
      @reply="onMenuReply"
      @react="onMenuReact"
      @copy-text="copyBody"
      @kind="onMenuKind"
      @move-channel="openMovePicker('channel')"
      @move-topic="openMovePicker('topic')"
      @merge-topic="openMovePicker('merge')"
      @promote-topic="onPromote"
      @make-issue="onMakeIssue"
      @hide-flow="onMenuHide"
    />
    <!-- SPL-1024: Move to channel… / Move to topic…, mounted when picked -->
    <LazyMovePickerDialog
      v-if="movePicker"
      :open="Boolean(movePicker)"
      :mode="movePicker"
      :msg="msg"
      :topic-task="moveCtx?.topic || ''"
      @update:open="(v: boolean) => { if (!v) movePicker = '' }"
    />
    <!-- SPL-983: mounted when Delete is picked on a topic card, not before.
         CLE-77840: eager code (not Lazy), as the Delete KEY opens it: a lazy
         chunk is gone on a tab older than the last deploy and the chunk-reload
         would reload the page instead of asking. -->
    <TopicDeleteDialog
      v-if="topicDeleteOpen"
      v-model:open="topicDeleteOpen"
      :msg-id="topicDeleteMsgId || String(msg.msg_id || '')"
      @deleted="onTopicDeleted"
    />
    <!-- SPL-1001: the menu's Delete asks first; mounted only when picked
         (eager code, CLE-77840, as above) -->
    <MessageDeleteDialog
      v-if="msgDeleteOpen"
      v-model:open="msgDeleteOpen"
      @confirm="remove"
    />
    <!-- mounted only while open (CLE-35075): a closed picker per card cost an
         overlay registration, a watcher and a Teleport on every card -->
    <LazyEmojiPicker
      v-if="pickerOpen"
      :open="pickerOpen"
      :x="pickerAt.x"
      :y="pickerAt.y"
      @close="pickerOpen = false"
      @choose="onReact"
    />
  </article>
</template>

<script setup lang="ts">
/* r13-01: each part of the card is a composable (src/composables/useCard*.ts);
   the header, the menu flags and the pointer / click / key routing between
   the parts stay here. */
import { formatIsoTs, formatMsgListTs, formatTopicTs, headerRecipientOf, phoneCardTime, shownPerson } from '~/utils/channel-feed.mjs'
import { useMobileStack } from '~/composables/useMobileStack'
import { useHumanNames } from '~/composables/useHumanNames'
import { activityOf } from '~/utils/feed.mjs'
import { topicCounts } from '~/utils/read-cursor.mjs'
import { isEdited, wantsDblClickEdit, wantsEdit } from '~/utils/msg-edit.mjs'
import { useMessageEdit } from '~/composables/useMessageEdit'
import { useDrafts } from '~/composables/useDrafts'
import { useMessageMenu } from '~/composables/useMessageMenu'
import { holdPanel, stepSelection, useMsgShortcuts } from '~/composables/useMsgShortcuts'
import { useAccessStore } from '~/stores/access'
import { mayArchiveTopic, mayChangeTopic, paneArchiveOffer } from '~/utils/topic-archive.mjs'
import { useDeleteUndo } from '~/composables/useDeleteUndo'
import { deleteKeyAction, rowStep } from '~/utils/row-keys.mjs'
import { isAiMessage, typedByAuthor } from '~/utils/typed-by.mjs'
import { canSetKind } from '~/utils/msg-kind.mjs'
import { ownerAllows } from '~/utils/access.mjs'
import { POLL_HOST } from '~/utils/poll-fence.mjs'
import type { CardClipMode } from '~/composables/useCardClip'
import { LinkPreviewsLazy } from '~/composables/useLinkPreviewRefs'
import { useCardReactions } from '~/composables/useCardReactions'
import { useCardEdit } from '~/composables/useCardEdit'
import { useCardHeight, useCardTitle } from '~/composables/useCardHeight'
import { useCardMessageActions, useCardTopicActions } from '~/composables/useCardTopicActions'
import { useCardMenuActions } from '~/composables/useCardMenuActions'
import { useCardNotes } from '~/composables/useCardNotes'
import { useCardLongPress, useCardSwipe, useCardSwipeFlags } from '~/composables/useCardSwipe'
import { useCardMove, useCardMoveFlags } from '~/composables/useCardMove'
import { useCardTouchLift } from '~/composables/useCardTouchLift'

import type { FileRef, ReactionUpdate, SpoolMessage } from '~/types/spool'

const props = defineProps<{
  msg: SpoolMessage
  count?: number
  /** CLE-77804 (topic 35053f95): the reader's unread reply count for this topic. */
  unread?: number
  /** SPL-2422: the topic's first message is unseen by the reader (openerUnseen) - 1 more new. */
  openerNew?: boolean
  alwaysTopic?: boolean
  posinset?: number
  setsize?: number
  topicLink?: boolean
  /** the whole row opens its topic (pointer and keyboard). */
  clickable?: boolean
  /** the row the open topic is rooted at */
  selected?: boolean
  /** Date.now() at topic open (ticks while open): `yyyy-mm-dd HH:MM:SS sent <age>` */
  sinceMs?: number
  /** offer the `e` shortcut on this row (author-only; the host decides). */
  editable?: boolean
  /** The older message in this same thread, when this row may be folded into it. */
  mergePrev?: SpoolMessage | null
  /** The newer message in this same thread, when this row may be folded into it. */
  mergeNext?: SpoolMessage | null
  /** The task the list itself shows (#lobby), so a card's link names the right topic. */
  currentTaskId?: string | null
  /** titles / 5 rows / full. Omitted = show the whole card. */
  clipMode?: CardClipMode
  /** SPL-983: a middle-pane card, where Archive / Delete (the topic) may be offered. */
  topicMenu?: boolean
  /** SPL-1024: a thread row of an open topic, which may be moved to another
      topic (dragged onto a middle card, or Move to topic…). `channel` is the
      pane's channel for a row that names none, `opener` the card the pane
      was opened on (never movable), `topic` the pane's task. */
  moveCtx?: { channel?: string | null, opener?: string, topic?: string } | null,
  /** HUM-10 (owner, t1 7de82b71): a topic pane's latest message, the one
      that offers Archive topic. Set only in a topic pane, with paneOpener. */
  lastMsgId?: string
  /** ... and that pane's opening card: the archive permission is the topic's,
      read on it, never on the reply. undefined outside a topic pane. */
  paneOpener?: SpoolMessage | null
  /** SPL-1994: this post (or this topic row's topic) waits for an agent's answer. */
  awaiting?: 'spin' | 'wait' | null
}>()
const emit = defineEmits<{ 'open-topic': [msg: SpoolMessage], edited: [msg: SpoolMessage], deleted: [msg: SpoolMessage], reacted: [update: ReactionUpdate] }>()

const repliesName = computed(() => {
  const base = `${t('feed.replies', { n: props.count ?? 0 }, props.count ?? 0)} - ${t('feed.open_topic')}`
  /* CLE-77804: announce the unread part the bold number shows visually */
  return unreadCount.value > 0 ? `${t('feed.replies_unread', { n: unreadCount.value })}, ${base}` : base
})
/** The replies link opens this topic on the right. The left tab stays as it was. */
function openReplies() {
  emit('open-topic', props.msg)
}
/* SPL-1637: the form in the body answers THIS message; its "Chat about this"
   opens the topic as Reply does (a thread line is already in it) */
provide(POLL_HOST, { msg: () => props.msg, open: () => { if (props.clickable) openReplies() } })

const { t, te } = useI18n({ useScope: 'global' })
const people = useHumanNames()
function whoOf(p: { id?: string, box?: string } | null | undefined) {
  if (!p?.id) return t('feed.unknown_author')
  return shownPerson(p.id, p.box, people.names.value)
}
/** specs/036 FR-011: who the row is shown as (the typist, for a terminal line). */
const author = computed(() => typedByAuthor(props.msg))
/* HUM-24: an AI agent's row is tinted and badged (a typed-as-human line is not) */
const ai = computed(() => isAiMessage(props.msg))
/** v:1 kind in words (feed.kind.*); an unknown kind shows as sent. */
const kindLabel = (k: string) => (te('feed.kind.' + k) ? t('feed.kind.' + k) : k)
/* a topic card is ordered by its LAST activity, so it shows that
   moment — a card that sits above another must not print an older time. */
const at = computed(() => activityOf(props.msg))
/*
 * The message list prints `yyyy-mm-dd HH:MM`: no T, no seconds, no Z.
 * The thread pane keeps its own clock (`sinceMs`).
 */
const fullTime = computed(() => (
  props.sinceMs != null
    ? formatTopicTs(at.value, props.sinceMs)
    : formatMsgListTs(at.value)
))
/* SPL-1000 (owner, "on mobile only"): a phone drops this year's `2026-`;
   SPL-1007: and today's date too, so a message from today shows only its
   time. The hover keeps the whole value. Desktop prints fullTime unchanged. */
const mobile = useMobileStack().isMobile
const time = computed(() => (mobile.value ? phoneCardTime(fullTime.value, at.value) : fullTime.value))
/* CLE-77840: always titled - the time may be cut short with an ellipsis */
const timeTitle = computed(() => (props.sinceMs == null ? formatIsoTs(at.value) : (time.value !== fullTime.value ? fullTime.value : time.value)))
/* SPL-981: a direct message shows only its sender; channel rows keep sender -> recipient */
const recipient = computed(() => headerRecipientOf(props.msg))
const files = computed(() => (Array.isArray(props.msg.files) ? props.msg.files : []) as FileRef[])
const count = computed(() => props.count || 0)
/* the unread replies are capped at the replies (a stale snapshot never shows n/less-than-n);
   SPL-2422: the first message is counted too (topicCounts) */
const counts = computed(() => topicCounts(count.value, Number(props.unread) || 0, Boolean(props.openerNew)))
const unreadCount = computed(() => counts.value.unseen)
const total = computed(() => counts.value.total)
const edited = computed(() => isEdited(props.msg))

/* the template refs: the row, the edit box, and the clip box with its content */
const rowEl = ref<HTMLElement | null>(null)
const editEl = ref<HTMLTextAreaElement | null>(null)
const clipEl = ref<HTMLElement | null>(null)
const clipInner = ref<HTMLElement | null>(null)
const removing = ref(false)
const editError = ref('')
const localePath = useLocalePath()
const msgEdit = useMessageEdit()
const { canEdit, viewerId: editorId, removeAttachment } = msgEdit
const { editing, saving, editHintId, draft, editMp, startEdit, onEditKey } = useCardEdit(props, emit, rowEl, editEl, editError, msgEdit)
/* The same message can sit in the middle list and the topic pane at once.
   The menu id has to be this card, not the msg_id, or both menus open. */
const menuKey = useId()
const menu = useMessageMenu(() => menuKey)
const { open: menuOpen, point: menuPoint, openAt: openMenuAt, close: closeMenu } = menu
const {
  viewerId, pickerOpen, pickerAt, busy, reactError, chips, emojiLabel, chipTitle, phoneChips, emojiBtnName, openPickerFromButton, onReact,
} = useCardReactions(props, emit, rowEl, mobile, menu)
function onMenuReact() {
  closeMenu()
  pickerAt.value = { x: 0, y: 0 }
  pickerOpen.value = true
}

/* spec 080 FR-005: a topic card whose topic holds the member's reply draft */
const drafts = useDrafts()
const hasDraft = computed(() => props.msg.is_parent !== 0 && Boolean(props.msg.task_id) && drafts.has('t:' + String(props.msg.task_id)))
/* SPL-1560: the X on each file card, for whoever may edit the message (its
   author, the tenant owner or an admin; the hub checks the same rule). The
   changed row goes to every store; `edited` tells a host that holds its own
   copy (the issue comments). */
const filesRemovable = computed(() => Boolean(props.editable) && canEdit(props.msg))
async function removeFile(f: FileRef) {
  const rows = await removeAttachment(String(f.file_id || f.sha256 || ''))
  const row = rows.find((r) => r.msg_id === props.msg.msg_id)
  if (row) emit('edited', { ...props.msg, ...row })
}
/* SPL-983 (specs/041 §3.3) / CLE-77819: Delete is the author, the tenant owner
   or an admin; Archive also a member the card is addressed to. The hub
   re-checks; this only decides what the menu offers. */
const access = useAccessStore()
const showTopicDelete = computed(() => Boolean(props.topicMenu) && mayChangeTopic(props.msg, editorId.value, access.me))
/* HUM-10 (owner, t1 7de82b71): in a topic pane only the LATEST message offers
   Archive topic, on the opener's permission; elsewhere the topic card does */
const inPane = computed(() => props.paneOpener !== undefined)
const showTopicArchive = computed(() => (inPane.value
  ? paneArchiveOffer(props.msg, props.lastMsgId || '', props.paneOpener, editorId.value, access.me)
  : Boolean(props.topicMenu) && mayArchiveTopic(props.msg, editorId.value, access.me)))
/* ... on a reply (not the topic card) it keeps the message's own Delete */
const paneArchiveReply = computed(() => inPane.value && !props.topicMenu && showTopicArchive.value)
const kindSettable = computed(() => canSetKind(props.msg, editorId.value, access.me?.role ?? null))
/* t1 5ea2e615 (owner db5ed497): a workspace owner makes an issue of a blocker */
const canMakeIssue = computed(() => ownerAllows(access.me) && String(props.msg.kind || '') === 'blocker')

const { titleOnly, linkPreviews, title } = useCardTitle(props, editing, files)
const { clipOn, userPx, clipped, clipStyle, startGrip, onGripClick, onGripKey } = useCardHeight(props, editing, clipEl, clipInner)
const busyState = { removing, editError }
const { topicDeleteOpen, topicDeleteMsgId, msgDeleteOpen, onMenuArchive, onMenuDeleteTopic, onTopicDeleted, onMenuDelete } = useCardTopicActions(props, emit, rowEl, busyState, menu, msgEdit)
const { aiError, onAiFail, onMerge, remove, onMakeIssue } = useCardMessageActions(props, emit, busyState, editing, menu, msgEdit)
const { showParent, parentKind, onMenuParent, copyMessageLink, copyBody, onMenuOpen, onMenuReply, onMenuKind } = useCardMenuActions(props, viewerId, rowEl, menu, openReplies)

const { movedFrom, movedText, dmRef, dmRefText, dmRefTip, pointerText, pointerTip } = useCardNotes(props)

const longPress = useCardLongPress(editing, pickerOpen, menu)
const { inTopicPane, swipeOn, swipeArchive, swipeLeft, menuHide } = useCardSwipeFlags(props, editing, rowEl, inPane, showTopicArchive,
  () => mayArchiveTopic(props.msg, editorId.value, access.me))
const { swipe, swipeDx, swipeDir, swipeArmed, swipeSettle, onMenuHide } = useCardSwipe(props, rowEl, swipeLeft, pickerOpen, menu, {
  stop: () => { longPress.cancel(); rowDrag.cancel() },
  archive: onMenuArchive,
})
/** a swipe may start on the row or on its move handle */
function swipeDown(ev: PointerEvent) {
  if (swipeOn.value && !removing.value) swipe.down(ev)
}
const moveFlags = useCardMoveFlags(props, editing, inTopicPane, editorId, access)
const { move, canMoveTopic, canMoveMsg, canPromoteMsg, movable, menuLocks, dropTarget, dropOver } = moveFlags
const mv = useCardMove(props, moveFlags, title, pickerOpen, menu, { swipeDown, cancelRowDrag: () => rowDrag.cancel() })
const { dragging, movePicker, handle, onHandleDown, onHandleUp, openMovePicker, onPromote } = mv
const { touchLift, rowDrag } = useCardTouchLift(rowEl, editing, mv, () => { longPress.cancel(); swipe.cancel() }, pickerOpen, menu)
const deleteUndo = useDeleteUndo()

/*
 * clicking the row opens its topic. The row already carried
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
  /* SPL-991: the finger that long-pressed lifts with a click; it opened the
     menu and must not also open the topic */
  if (longPress.takeClick()) {
    ev.preventDefault()
    return
  }
  /* CLE-77906: nor does the finger that swiped */
  if (swipe.takeClick()) {
    ev.preventDefault()
    return
  }
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

/*
 * HUM-10 (owner, t1 86698d8a): on a phone a thumb held on the card's TEXT is
 * the browser's own long press: it selects a word, with handles and the
 * native copy pop-up, so part of a message can be copied. The text is the
 * one selectable part of the card (the CSS below); the card's own long press
 * (the menu, or the topic lift) stays on the rest of it, and the ⋯ button
 * opens the menu from anywhere.
 */
const TEXT_SELECT = '.msg-body'
let touchOnText = false
function onTextTouch(ev: PointerEvent): boolean {
  const el = ev.target as HTMLElement | null
  touchOnText = ev.pointerType === 'touch' && !editing.value && Boolean(el?.closest?.(TEXT_SELECT))
  return touchOnText
}

function onContextMenu(ev: MouseEvent) {
  /* HUM-10 (86698d8a): the browser's selection pop-up, not the card menu */
  if (touchOnText) return
  /* HUM-10: Android's long press fires contextmenu while the finger is still
     on a card it may lift; the hold (or its release in place) decides */
  if (rowDrag.state !== 'idle') {
    ev.preventDefault()
    return
  }
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

function onRowDown(ev: PointerEvent) {
  /* HUM-10: a finger on a topic card it may move lifts it on the hold (the
     long-press menu then opens on a release in place, see rowDrag) */
  if (onTextTouch(ev)) longPress.cancel()
  else if (touchLift.value && ev.pointerType === 'touch') rowDrag.down(ev)
  else longPress.down(ev)
  swipeDown(ev)
}
function onRowMove(ev: PointerEvent) {
  rowDrag.move(ev)
  if (rowDrag.state === 'lifted') return
  longPress.move(ev)
  swipe.move(ev)
}
function onRowUp(ev: PointerEvent) {
  rowDrag.up(ev)
  longPress.up()
  swipe.up()
}
function onRowCancel() {
  rowDrag.cancel()
  longPress.cancel()
  swipe.cancel()
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

/* Delete / Backspace on the selected row. A topic-level message
   (is_parent 1) asks first, with the same confirm as the menu; a reply goes
   at once and the "Deleted · Undo" snackbar offers it back. Who may delete
   is the menu's gate, unchanged. preventDefault stops Backspace from
   walking the browser history. True when the key was a delete. */
function onDeleteKey(ev: KeyboardEvent): boolean {
  const del = editing.value || removing.value
    ? ''
    : deleteKeyAction(ev, props.msg, { topicDelete: showTopicDelete.value, editable: Boolean(props.editable) && canEdit(props.msg) })
  if (!del) return false
  ev.preventDefault()
  /* HUM-10 c13e8023: the focus stays in this card's panel (useMsgShortcuts) */
  holdPanel(rowEl.value)
  if (del === 'confirm-topic') void onMenuDeleteTopic()
  else if (del === 'confirm-message') msgDeleteOpen.value = true
  else {
    /* the host drops it from its own rows; Undo hands it back (onDeleteRestore) */
    deleteUndo.offer(props.msg)
    emit('deleted', props.msg)
  }
  return true
}

function onKey(ev: KeyboardEvent) {
  /* `e` on the focused row opens the editor. Checked BEFORE the
     open-topic keys so a row that is editable but not clickable still takes
     it, and guarded by the same target === currentTarget rule. */
  if (wantsEdit(ev, { editable: props.editable && !editing.value })) {
    ev.preventDefault()
    startEdit()
    return
  }
  /* CLE-77840 (owner, topic bc1fd547): ArrowDown / ArrowUp walk the focus,
     which is the selection, to the next / previous message of this feed. */
  const step = editing.value ? 0 : rowStep(ev)
  if (step) {
    if (stepSelection(rowEl.value, step)) ev.preventDefault()
    return
  }
  if (onDeleteKey(ev)) return
  if (!props.clickable) return
  if (ev.key !== 'Enter' && ev.key !== ' ' && ev.key !== 'Spacebar') return
  /* only the row itself: Enter inside a child control is that control's */
  if (ev.target !== ev.currentTarget) return
  ev.preventDefault()
  emit('open-topic', props.msg)
}

/* HUM-10 ae2e5093: Shift + letter on the selected card runs the same handler
   as its menu item, offered by the same flags (composables/useMsgShortcuts.ts) */
const shortcutRun: Record<string, () => unknown> = {
  open: onMenuOpen, parent: onMenuParent, edit: onMenuEdit, copy: copyMessageLink, 'copy-text': copyBody,
  reply: onMenuReply, kind: onMenuKind, archive: onMenuArchive, delete: onMenuDelete, 'delete-topic': onMenuDeleteTopic,
  'move-channel': () => openMovePicker('channel'), 'move-topic': () => openMovePicker('topic'),
  'merge-topic': () => openMovePicker('merge'), 'promote-topic': onPromote, 'hide-flow': onMenuHide,
}
/* HUM-10 t1 4c5161e3: Shift + R opens this card's menu at the row, the
   same point as the … button, so the first item can take the focus. */
function openMenuFromShortcut() {
  const row = rowEl.value
  if (!row) return
  const btn = row.querySelector<HTMLElement>('[data-testid="msg-menu-btn"]')
  const anchor = btn ?? row
  const r = anchor.getBoundingClientRect()
  row.focus({ preventScroll: true })
  if (btn) openMenuAt(r.left, r.bottom + 4)
  else openMenuAt(r.left + 12, r.top + 12)
}
useMsgShortcuts({
  row: rowEl,
  busy: () => editing.value || removing.value,
  run: (id) => shortcutRun[id]?.(),
  openMenu: openMenuFromShortcut,
  flags: () => ({
    editable: !!props.editable && !editing.value, parent: showParent.value, parentKind: parentKind.value,
    topicArchive: showTopicArchive.value, paneArchive: paneArchiveReply.value, topicDelete: showTopicDelete.value, kind: kindSettable.value,
    moveChannel: canMoveTopic.value, mergeTopic: canMoveTopic.value, moveTopic: canMoveMsg.value,
    promoteTopic: canPromoteMsg.value, hide: menuHide.value, locks: menuLocks.value,
  }),
})

onMounted(() => {
  if (typeof window === 'undefined') return
  const hash = decodeURIComponent(window.location.hash.replace(/^#/, ''))
  if (hash && hash === String(props.msg?.msg_id || '')) rowEl.value?.focus({ preventScroll: true })
})
</script>

<style scoped>
/* t1 b921518d: the selected topic card has no left bracket bar. A 1px
   soft-grey border frames all four sides, and a small grey drop shadow
   lifts it. The card is not translated: scroll-to-top reads the border
   box, and a 1px shift leaves the card 1px off the edge once the
   selection clears. Keyboard focus stays the global :focus-visible
   outline. A swipe keeps its own translateX. */
.msg.selected {
  position: relative;
  z-index: 1;
  /* t1 b921518d follow-up: a soft grey, low opacity. Keyboard focus
     keeps the global outline. */
  border: 1px solid rgba(128, 128, 128, 0.45);
  box-shadow: 0 2px 6px rgba(100, 100, 100, 0.22);
}
.mention-anchor { position: relative; min-width: 0; }
/*
 * the recipient half of the owner's row format.
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
.msg-ai-badge {
  align-self: center;
  flex: 0 0 auto;
  padding: 0 5px;
  border-radius: var(--radius-pill);
  border: 1px solid var(--color-accent);
  color: var(--color-fg);
  font-size: 0.6875rem;
  font-weight: 600;
  line-height: 1.4;
  letter-spacing: 0.02em;
  white-space: nowrap;
}
/* spec 067: the DM-ref line is the moved line, its link in the same muted ink */
.msg-dm-ref a { color: inherit; }
/* spec 068 L8: the responsible seat gives way like the time (ellipsis, title) */
.msg-responsible {
  flex: 0 1 auto;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--color-muted);
  font-size: 0.75rem;
}
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
/* CLE-77840 (owner, topic d837af50): the time is what gives way on a narrow
   pane (ellipsis; the full time is its title). It used to be fixed, so the
   topic pane's long "2026-09-27 11:16:01 sent 94h 23m" pushed the smile
   button and the reaction chips past the pane's edge, where they were clipped. */
.msg-meta > .msg-time { flex: 0 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.msg-time--sending { font-style: italic; }
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
.msg-meta > .msg-draft { order: 2; display: inline-flex; align-items: center; color: var(--color-muted); flex-shrink: 0; }
/* SPL-1024: "moved from ..." sits beside "(edited)", muted and small */
.msg-moved {
  margin: 0;
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--color-muted);
  font-size: 0.75rem;
}
/* SPL-1134: the ONE card under a dragged reply is lit; the dragged row fades */
.msg--move-over { background: var(--color-selected); outline: 2px solid var(--focus-ring); outline-offset: -2px; }
.msg--dragging { opacity: 0.5; }
/* HUM-10: swipe left to archive, right for the menu (touch only). pan-y
   leaves the vertical scroll to the browser and gives the horizontal move to
   the card. The whole card slides by --swipe-dx (signed; its content is
   display: contents on a phone, so it cannot move on its own) and the strip,
   pinned just past the edge it uncovers (--swipe-w wide), fills the gap with
   the archive or menu icon (accent once past the threshold). */
.msg--swipe { position: relative; touch-action: pan-y; }
.msg--swiping,
.msg--swipe-settle { transform: translateX(var(--swipe-dx, 0px)); }
.msg--swipe-settle { transition: transform 0.18s ease-out; }
:global(html[dir="rtl"]) .msg--swiping,
:global(html[dir="rtl"]) .msg--swipe-settle { transform: translateX(calc(-1 * var(--swipe-dx, 0px))); }
.msg-swipe-reveal {
  position: absolute;
  inset-block: 0;
  width: var(--swipe-w, 0px);
  display: flex;
  align-items: center;
  gap: 6px;
  padding-inline-start: 12px;
  overflow: hidden;
  white-space: nowrap;
  border-radius: var(--radius);
  background: var(--color-selected);
  color: var(--color-muted);
  font-size: 0.8125rem;
  font-weight: 600;
  pointer-events: none;
}
.msg-swipe-reveal--start { inset-inline-start: calc(-1 * var(--swipe-w, 0px)); }
.msg-swipe-reveal--end { inset-inline-end: calc(-1 * var(--swipe-w, 0px)); justify-content: flex-end; padding-inline: 0 12px; }
.msg-swipe-reveal[data-armed] { background: var(--color-accent); color: var(--color-on-accent); }
@media (prefers-reduced-motion: reduce) {
  .msg--swipe-settle { transition: none; }
}
/* SPL-1134 (specs/045 §3.9): the handle is the card's first 12 px (~3 mm).
   At rest it is invisible; on hover it tints and shows a grip, the cursor
   says grab (grabbing while lifted, not-allowed over a refusing row). */
.msg--movable { position: relative; }
.msg-move-handle {
  position: absolute;
  inset-block: 0;
  inset-inline-start: 0;
  width: 12px;
  z-index: 2;
  border-start-start-radius: var(--radius);
  border-end-start-radius: var(--radius);
  cursor: grab;
  touch-action: none;
  -webkit-user-select: none;
  user-select: none;
  -webkit-touch-callout: none;
}
.msg-move-handle:hover,
.msg--dragging .msg-move-handle {
  background-color: color-mix(in srgb, var(--color-accent) 18%, transparent);
  background-image: radial-gradient(circle, var(--color-accent) 1.2px, transparent 1.6px);
  background-size: 6px 6px;
  background-position: 0 center;
  background-repeat: repeat;
}
.msg--dragging .msg-move-handle { cursor: grabbing; }
.msg--dragging .msg-move-handle--denied { cursor: not-allowed; }
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
/* SPL-1762 (ui panel 34f4da14, item 4): a card off screen skips its style,
   layout and paint; 72px is the one-line card's height until it has been
   drawn once, then the browser keeps its real size (`auto`). Paint
   containment clips at the card's edge, so a card that is swiping (its strip
   sits just outside) or holds the focus (the edit box's mention list, the
   open menu) draws normally. */
.msg:not(.msg--swiping):not(.msg--swipe-settle):not(:focus-within) {
  content-visibility: auto;
  contain-intrinsic-size: auto 72px;
}
/* SPL-1750 (item 5, desktop): Open topic, an empty "0 >>", the smile and the
   menu show on hover or keyboard focus only, so a quiet feed has no column of
   icons. opacity, not display: they keep their place (no shift on hover),
   their click target and the Tab order. A count above 0 is news and stays.
   A touch screen (hover: none) and the phone stack always show them. */
@media (hover: hover) and (min-width: 821px) {
  .msg-actions [data-test="open-topic"],
  .msg-actions .replies[data-zero],
  .msg-actions .icon-btn[data-testid="msg-emoji-btn"],
  .msg-actions .msg-menu-btn {
    opacity: 0;
    transition: opacity 120ms ease;
  }
  .msg:hover .msg-actions > *,
  .msg:focus-within .msg-actions > *,
  .msg.selected .msg-actions > *,
  .msg-actions > [aria-expanded="true"] { opacity: 1; }
}
@media (hover: hover) and (min-width: 821px) and (prefers-reduced-motion: reduce) {
  .msg-actions > * { transition: none; }
}
/*
 * the middle pane's clipped card. The fallback cap is the same
 * rule as utils/card-clip.mjs (5 rows of the body's 0.875rem x 1.45, with or
 * without a picture, SPL-2121) so the card is already tight before the first
 * measurement; once measured, the inline max-height takes over. rem, so the
 * font-size setting moves it.
 */
.card-clip {
  max-height: calc(5 * 1.45 * 0.875rem);
  min-height: calc(5 * 1.45 * 0.875rem);
  overflow: hidden;
}
/* SPL-1871: a ```poll form in a clipped card puts its answers line first,
   so who answered what reads within the 5 rows; the options follow */
.card-clip :deep(.poll) { display: flex; flex-direction: column; }
.card-clip :deep(.poll-answers) { order: -1; margin: 0 0 4px; }
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
.card-grip--room { cursor: default; pointer-events: none; }
.card-grip--room::after { content: none; }
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
/* SPL-991 phone (<= 820 px): the card is full width and the header is one
   line - the names give way first (ellipsis) and the reactions take their own
   wrapping row under it, so nothing ever widens the page. The smile and the
   Open-topic icons leave the row (the long-press sheet has Add emoji and
   Open, and a tap on the card opens it); the ⋯ stays as the visible way to
   the sheet. Every control left is a 44 px target. A long press must not
   select text or pop the iOS callout: Copy text is in the sheet.
   LAST in this sheet on purpose: it overrides same-specificity rules above
   (.card-grip, .msg-reaction, .msg-meta > .msg-reactions) by order. */
@media (max-width: 820px) {
  /* (owner, topics 95adf832 + fd1e5be4): the card's text near
     either screen edge (10 px: 6 was "a bit too much"), "the max amount of the screen area must be
     used". The header row keeps the avatar column; everything under it (the
     body, the files, the clip, the grip, the edit box) spans the whole card,
     so the text starts under the avatar: 6 px list inset + 4 px card inset. */
  .msg {
    grid-template-columns: 32px minmax(0, 1fr);
    gap: 0 8px;
    /* SPL-1000 (owner): the avatar 4px from the card's left edge */
    padding: 8px 4px;
    -webkit-touch-callout: none;
    -webkit-user-select: none;
    user-select: none;
  }
  .msg textarea { -webkit-user-select: text; user-select: text; }
  /* HUM-10 (owner, t1 86698d8a): except its text, where a long press is the
     browser's own selection (handles, the native copy pop-up) */
  .msg :deep(.msg-body) {
    -webkit-touch-callout: default;
    -webkit-user-select: text;
    user-select: text;
  }
  .msg > .avatar { width: 32px; height: 32px; }
  .msg-main { display: contents; }
  .msg-main > * { grid-column: 1 / -1; min-width: 0; }
  .msg-main > .msg-meta { grid-column: 2; }
  .msg-meta { flex-wrap: wrap; gap: 4px; }
  /* SPL-1000: the header is ONE line at 360 px with Add emoji in it. The row
     wraps (the reactions take their own line below), and a flex item wraps at
     its basis before it shrinks - so every name-like item has basis 0 and a
     small floor: the names give way first, with an ellipsis */
  .msg-meta > :deep(.msg-author) { flex: 1 1 0; max-width: max-content; min-width: 1em; }
  /* the name takes the free space first (up to its own width); an auto
     margin then takes what is left, so the menu still sits at the right edge
     on either header line (a grow below 1 would hand out only that fraction
     of the free space and strand the menu mid-row) */
  .msg-meta-spacer { flex: 0 0 0; margin-inline-start: auto; }
  .msg-meta > .msg-via-terminal { flex: 1 1 0; max-width: max-content; min-width: 1em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  /* spec 068 L8: the seat gives way on the header line, as the typist does */
  .msg-meta > .msg-responsible { flex: 1 1 0; max-width: max-content; min-width: 1em; }
  .msg-actions [data-test="open-topic"] { display: none; }
  /* SPL-1750 (item 5, phone): the sender's name gets the header. "0 >>" goes
     (a tap on the card opens its topic); the name takes the free space up to
     its full width before the typist and seat badges do. The kind icon stays:
     a hold just under the header lands on it (touch adjustment) and lifts the
     card or opens its menu, where the body text would select instead */
  .msg-actions .replies[data-zero] { display: none; }
  .msg-meta > :deep(.msg-author) { flex-grow: 100; }
  /* SPL-1000 (owner, SPL-982 rule on every card): Add emoji stays in the
     header on a phone too - a 44 px target whose 16 px glyph sits 5 px after
     the time (4px row gap + 14px padding - 13px). Long-press keeps it too. */
  .msg-actions .icon-btn[data-testid="msg-emoji-btn"] {
    width: var(--tap); height: var(--tap); min-width: var(--tap); min-height: var(--tap);
    margin-block: -6px; margin-inline-start: -13px; flex: 0 0 auto;
  }
  /* SPL-1007 (owner, topic 70c82b54, "twice as small", "right next to the
     set emoji icon"): the chips are drawn inside Add emoji - a 22 px pill
     (half the old 44) with a 0.5rem glyph (half the old 1rem), 3px after the
     smile on the header line. The button stays one >= 44 px target: its
     start padding keeps the smile 5 px after the time, and it takes the
     room the names give up (basis 0, up to its own width), its chips
     wrapping inside it when the line is short */
  .msg-actions .icon-btn.msg-emoji-btn--chips {
    width: auto; min-width: min-content; flex: 1 0 0; max-width: max-content;
    justify-content: flex-start; gap: 3px; padding-inline: 14px 4px;
    /* its 44 px square reaches 6 px under the header: above the body text */
    position: relative; z-index: 1;
  }
  .msg-reactions--phone { display: inline-flex; flex-wrap: wrap; align-items: center; gap: 3px; min-width: 0; line-height: 1; }
  .msg-reactions--phone .msg-reaction { min-height: 22px; min-width: 0; padding: 0 5px; gap: 2px; font-size: 0.5rem; }
  .msg-reactions--phone .msg-reaction__n { font-size: 0.5rem; }
  /* its 44 px target reaches the card's 4 px right padding, and the
     arrow gives back its side bearing: a sender -> recipient header fits one
     line at 360 px (SPL-1000) */
  .msg-actions .msg-menu-btn { width: var(--tap); height: var(--tap); min-width: var(--tap); min-height: var(--tap); margin-block: -6px; margin-inline-end: -4px; }
  .msg-to-arrow { margin-inline: -2px; }
  .msg-actions .replies { min-height: var(--tap); margin-block: -6px; padding-inline: 10px; }
  .msg-meta > .msg-reactions { order: 10; flex: 1 0 100%; margin-inline-start: 0; }
  .msg-reaction { min-height: var(--tap); min-width: var(--tap); justify-content: center; font-size: 1rem; }
  .card-grip { height: var(--tap); margin-top: -16px; }
  .card-grip::after { margin-top: 20px; }
}
</style>
