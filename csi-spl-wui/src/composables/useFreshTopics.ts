/*
 * Spec 189 row B2: the tab's one fresh-topics state (utils/topic-list-order.mjs).
 * Module scope on purpose: per tab, in memory, gone on a reload (C6). The
 * channel store records the viewer's own new-topic sends and the channel
 * switches; the channel feed reads the ids and ends the pin on a route off
 * the channel.
 */
import { shallowRef } from 'vue'
import { freshEmpty, freshEndsOnRoute, freshIdsFor, freshNote, type FreshEvent, type FreshState } from '~/utils/topic-list-order.mjs'

const state = shallowRef<FreshState>(freshEmpty())

export function useFreshTopics() {
  function note(ev: FreshEvent) {
    if (!import.meta.client) return
    const next = freshNote(state.value, ev)
    if (next !== state.value) state.value = next
  }
  /** the fresh task ids of `channel`, oldest send first */
  function idsFor(channel: string | null | undefined): string[] {
    return freshIdsFor(state.value, channel)
  }
  /** D2: a route off the channel (not its feed, not a topic page) ends the pin */
  function leaveTo(toPath: string) {
    if (state.value.channel && freshEndsOnRoute(toPath, state.value.channel)) note({ type: 'leave' })
  }
  return { note, idsFor, leaveTo }
}
