import { defineStore } from 'pinia'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { replyCount, topLevel } from '~/utils/channel-feed.mjs'
import type { ChannelRow, SpoolMessage } from '~/types/spool'

export type { ChannelRow }

export const useChannelStore = defineStore('channel', () => {
  const api = useSpoolApi()
  const channels = ref<ChannelRow[]>([])
  const active = ref<string | null>(null)
  const peer = ref<string | null>(null)
  const messages = ref<SpoolMessage[]>([])
  const unread = ref<Record<string, number>>({})
  const loading = ref(false)
  const error = ref<string | null>(null)

  const feed = computed(() => topLevel(messages.value))

  function key() {
    return peer.value ? `dm:${peer.value}` : `ch:${active.value || ''}`
  }

  async function loadChannels() {
    channels.value = await api.listChannels()
  }

  async function selectChannel(name: string) {
    peer.value = null
    active.value = name
    unread.value[name] = 0
    await refresh()
  }

  async function selectDm(id: string) {
    active.value = null
    peer.value = id
    unread.value[`dm:${id}`] = 0
    await refresh()
  }

  async function refresh() {
    loading.value = true
    error.value = null
    try {
      messages.value = await api.listMessages({
        channel: active.value || undefined,
        peer: peer.value || undefined,
        limit: 50,
      }) as unknown as SpoolMessage[]
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'load failed'
    } finally {
      loading.value = false
    }
  }

  async function send(text: string, parentTaskId?: string, files?: unknown[]) {
    const body = await api.sendMessage({
      channel: active.value,
      peer: peer.value || undefined,
      text,
      parent_task_id: parentTaskId,
      files,
    })
    const row = body as unknown as SpoolMessage
    messages.value = [...messages.value, row]
    return row
  }

  async function createChannel(name: string) {
    const row = await api.createChannel({ name })
    await loadChannels()
    await selectChannel(row.channel_id)
    return row
  }

  function repliesFor(taskId: string) {
    return replyCount(messages.value, taskId)
  }

  return {
    channels,
    active,
    peer,
    messages,
    unread,
    loading,
    error,
    feed,
    key,
    loadChannels,
    selectChannel,
    selectDm,
    refresh,
    send,
    createChannel,
    repliesFor,
  }
})
