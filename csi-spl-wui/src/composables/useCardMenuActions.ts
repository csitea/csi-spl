/*
 * MessageCard's menu items that go somewhere (r13-01): Open, Reply, Open
 * parent section, Kind, and the two copies.
 */
import { computed, nextTick, type Ref } from 'vue'
import { writeClipboard } from '~/utils/clipboard.mjs'
import { dmPeerOf } from '~/utils/channel-feed.mjs'
import { openThreadRow } from '~/utils/pane-scroll.mjs'
import { threadLineLink, topicPaneLink } from '~/utils/msg-menu.mjs'
import { COMPOSER_FOCUS_EVENT } from '~/utils/touch-ui.mjs'
import { useViewPrefs } from '~/composables/useViewPrefs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import type { CardMenu } from '~/composables/useCardReactions'
import type { SpoolMessage } from '~/types/spool'

type MenuProps = { msg: SpoolMessage, clickable?: boolean, currentTaskId?: string | null }

/* a thread line (not a middle card) can go back to where its
   thread lives: the channel or DM with the parent card selected, or the
   issue whose discussion it is. Shown by the same rule as utils/parent-section.mjs parentSection: a channel, or a
   DM end that is not the viewer. What the item does is loaded when it is
   chosen, so it is not in the initial JS (specs/027, 210 KB gzip). */
function useCardParent(props: MenuProps, viewerId: Ref<string>, menu: CardMenu) {
  const { close: closeMenu } = menu
  const showParent = computed(() => !props.clickable
    && Boolean(String(props.msg.channel || '').trim().replace(/^#/, '') || dmPeerOf(props.msg, viewerId.value)))
  /* HUM-10 (topic c15b557e): the item names its place - a DM "Open in direct
     msg view", a channel "Open in channels view"; the issue channel (or the
     retired #tasks) keeps "Open parent section". utils/parent-section.mjs
     parentKindOf is the same rule. */
  const parentKind = computed(() => {
    const ch = String(props.msg.channel || '').trim().replace(/^#/, '').toLowerCase()
    if (ch) return ch === 'issues' || ch === 'tasks' ? 'issue' : 'channel'
    return dmPeerOf(props.msg, viewerId.value) ? 'dm' : ''
  })
  const parentDeps = { api: useSpoolApi(), router: useRouter() }
  const localePath = useLocalePath()
  /* the card lands at the reader's edge: the top newest first, the bottom newest last */
  const { newestLast } = useViewPrefs()
  async function onMenuParent() {
    closeMenu()
    const m = await import('~/utils/parent-section-open.mjs')
    await m.openParentSection(props.msg, { ...parentDeps, localePath, self: viewerId.value, newestLast: newestLast.value, topicLevel: true, showPlace: true })
  }
  return { showParent, parentKind, onMenuParent }
}

/** Copy link and Copy text. */
function useCardCopy(props: MenuProps) {
  const route = useRoute()
  const localePath = useLocalePath()
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
    await copyString(new URL(path, window.location.origin).href)
  }

  /* SPL-991: a phone cannot select text inside a long-pressable card */
  async function copyBody() {
    const body = String(props.msg.body || '')
    if (body) await copyString(body)
  }

  async function copyString(value: string) {
    await writeClipboard(value)
  }
  return { copyMessageLink, copyBody }
}

export function useCardMenuActions(props: MenuProps, viewerId: Ref<string>, rowEl: Ref<HTMLElement | null>, menu: CardMenu, openReplies: () => void) {
  const { close: closeMenu } = menu
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

  /* Reply: a topic card opens its topic (the third panel); a thread line is
     already in it. Either way the caret goes to the docked composer. */
  function onMenuReply() {
    closeMenu()
    if (props.clickable) openReplies()
    if (typeof window !== 'undefined') {
      void nextTick(() => window.dispatchEvent(new CustomEvent(COMPOSER_FOCUS_EVENT)))
    }
  }

  /* Kind: the badge's own picker (KindBadge -> KindPicker), a sheet on a phone */
  function onMenuKind() {
    closeMenu()
    void nextTick(() => rowEl.value?.querySelector<HTMLElement>('[data-testid="kind-badge-btn"]')?.click())
  }
  return { ...useCardParent(props, viewerId, menu), ...useCardCopy(props), onMenuOpen, onMenuReply, onMenuKind }
}
