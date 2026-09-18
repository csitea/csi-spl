import { defineStore } from 'pinia'
import { applyVerbosity, threadOf } from '~/utils/channel-feed.mjs'
import { useChannelStore } from '~/stores/channel'

export type Verbosity = 'minimal' | 'normal' | 'verbose'

export const useThreadStore = defineStore('thread', () => {
  const open = ref(false)
  const parentTaskId = ref<string | null>(null)
  const verbosity = ref<Verbosity>('normal')

  const channel = useChannelStore()

  const messages = computed(() => {
    const all = threadOf(channel.messages, parentTaskId.value)
    return applyVerbosity(all, verbosity.value)
  })

  function openThread(taskId: string) {
    parentTaskId.value = taskId
    open.value = true
  }

  function close() {
    open.value = false
    parentTaskId.value = null
  }

  return { open, parentTaskId, verbosity, messages, openThread, close }
})
