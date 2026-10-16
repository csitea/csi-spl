/*
 * MessageCard's emoji reactions (r13-01): the chips, their names, the picker
 * the smile opens and the toggle a pick sends.
 *
 * The card's composables take their inputs as plain parameters, not as an
 * options object: a property name survives minification, a parameter does
 * not, and the card sits in the home page's budgeted JS (spec 027).
 */
import { computed, ref, watch, type Ref } from 'vue'
import { shownPerson } from '~/utils/channel-feed.mjs'
import { reactionChips, emojiName } from '~/utils/emoji.mjs'
import { useMessageEmoji } from '~/composables/useMessageEmoji'
import { useHumanNames } from '~/composables/useHumanNames'
import type { useMessageMenu } from '~/composables/useMessageMenu'
import type { ReactionUpdate, SpoolMessage } from '~/types/spool'

export type CardMenu = ReturnType<typeof useMessageMenu>

export function useCardReactions(
  props: { msg: SpoolMessage },
  emit: (e: 'reacted', update: ReactionUpdate) => void,
  rowEl: Ref<HTMLElement | null>,
  mobile: Ref<boolean>,
  menu: CardMenu,
) {
  const { t } = useI18n({ useScope: 'global' })
  const people = useHumanNames()
  const { viewerId, setReaction, applyEverywhere } = useMessageEmoji()
  const { close: closeMenu } = menu
  const pickerOpen = ref(false)
  const pickerAt = ref({ x: 0, y: 0 })
  const busy = ref(false)
  const reactError = ref('')
  const chips = computed(() => reactionChips(props.msg.reactions, viewerId.value))
  /** A chip's tooltip: who reacted, by the name the row would show. */
  function chipWho(actors: string[]) {
    return actors.map((id) => shownPerson(id, '', people.names.value)).join(', ')
  }
  /** The short, plain name of a reaction glyph (owner da0c0e98: hover names it). */
  function emojiLabel(emoji: string) {
    return emojiName(emoji, t)
  }
  /** A chip's title: what the emoji represents, then who reacted ("Fire · Ann"). */
  function chipTitle(chip: { emoji: string, actors: string[] }) {
    const who = chipWho(chip.actors)
    const name = emojiLabel(chip.emoji)
    return who ? `${name} · ${who}` : name
  }
  /* SPL-1007: a phone draws the chips inside Add emoji; its name reads them out */
  const phoneChips = computed(() => mobile.value && chips.value.length > 0)
  const emojiBtnName = computed(() => [t('feed.emoji.add'), ...chips.value.map((c) => (c.mine
    ? t('feed.emoji.mine', { emoji: emojiLabel(c.emoji) })
    : t('feed.emoji.chip', { emoji: emojiLabel(c.emoji), n: c.count })))].join(', '))

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

  /* another message under this card (useCardEdit's reset): no picker, no error, nothing in flight */
  watch(() => String(props.msg?.msg_id || ''), (now, before) => {
    if (now === before) return
    reactError.value = ''
    pickerOpen.value = false
    busy.value = false
  })

  return { viewerId, pickerOpen, pickerAt, busy, reactError, chips, emojiLabel, chipTitle, phoneChips, emojiBtnName, openPickerFromButton, onReact }
}
