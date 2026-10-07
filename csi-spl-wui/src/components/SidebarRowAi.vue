<!-- t1 b6c742f0 (HUM-10 643c30a8: "add them to every card which has right
     click menu"): the AI actions group of a topic row's menu (the sidebar
     Topics tab, the home topic list). Renders nothing: SidebarRowMenu mounts
     it (Lazy, v-if) only while a topic row's menu is open, so the group, its
     rule and the runner stay out of the initial JS. It hands the menu its
     entries (`items`, through useAiMenuGroup like every card menu) and runs a
     pick: the topic opens and the action runs on its opening message
     (useAiListRun runTopic). -->
<template>
  <span hidden />
</template>

<script setup lang="ts">
import { aiSubject } from '~/utils/msg-ai-actions.mjs'
import { useAiMenuGroup } from '~/composables/useAiMenuGroup'
import { useAiListRun } from '~/composables/useAiListRun'
import type { UiIconName } from '~/utils/uiIcons'

type Item = { id: string, icon: UiIconName, labelKey: string, groupKey?: string }

const props = defineProps<{
  taskId: string
  title: string
  base: Item[]
  /** reports a failed run: this component is gone by then, the menu is not */
  fail?: (key: string) => void
}>()
const emit = defineEmits<{
  items: [list: Item[]]
}>()

const ai = useAiMenuGroup(() => aiSubject('topic', { task_id: props.taskId, title: props.title }))
const list = useAiListRun()
watchEffect(() => emit('items', ai.items(props.base) as Item[]))

/**
 * The menu's pick of `id`: true when it is this group's (the menu does not
 * handle it). `stay` is true for the phone's "AI actions" entry: the sheet
 * stays open and shows the actions.
 */
function pick(id: string): { mine: boolean, stay: boolean } {
  if (ai.more(id)) return { mine: true, stay: true }
  if (!id.startsWith('ai-')) return { mine: false, stay: false }
  /* the run outlives this component: the menu closes (and unmounts it) at once */
  const fail = props.fail
  void list.runTopic(id, props.taskId).then((key) => { if (key) fail?.(key) })
  return { mine: true, stay: false }
}
defineExpose({ pick })
</script>
