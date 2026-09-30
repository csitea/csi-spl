<!-- SPL-1027 (owner, prd t1 topic 89485c7a): "opening one ... should open up
     as a modal dialog (on desktop and tablet) ... the right-most panel could
     be removed". The open issue's content stays in pages/issues.vue (its refs,
     its pickers, the discussion's postComment); this only picks the frame:
       modal  (> 820 px)  UiDialog, large: focus trap, Esc / X / backdrop
                          close, focus handed back to the row
       aside  (<= 820 px) the phone's level 3, full screen (SPL-992), unchanged
     Content only goes in the default slot, so neither frame knows an issue. -->
<template>
  <UiDialog v-if="modal" :open="open" :title="title" size="lg" @update:open="onOpen">
    <template v-if="$slots.tools" #tools><slot name="tools" /></template>
    <slot />
  </UiDialog>
  <aside v-else-if="open" v-bind="$attrs"><slot /></aside>
</template>

<script setup lang="ts">
defineOptions({ inheritAttrs: false })
defineProps<{
  /** true above 820 px: the issue is a modal dialog; false: the phone's level 3 */
  modal: boolean
  open: boolean
  /** the dialog's title (the issue key) */
  title: string
}>()
const emit = defineEmits<{ close: [] }>()
function onOpen(v: boolean) {
  if (!v) emit('close')
}
</script>
