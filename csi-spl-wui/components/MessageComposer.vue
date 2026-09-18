<template>
  <form class="composer" @submit.prevent="onSend">
    <div class="composer-box">
      <textarea
        v-model="text"
        rows="2"
        :placeholder="placeholder"
        @keydown.enter.exact.prevent="onSend"
      />
      <div class="composer-row">
        <label class="muted">
          <input type="file" multiple hidden @change="onFiles">
          attach
        </label>
        <button type="submit" :disabled="!text.trim()">Send</button>
      </div>
    </div>
  </form>
</template>

<script setup lang="ts">
const props = defineProps<{
  placeholder?: string
  parentTaskId?: string
}>()
const emit = defineEmits<{ send: [text: string, parentTaskId?: string] }>()
const text = ref('')

const placeholder = computed(() => props.placeholder || 'Message — @CLE-07 to task an agent')

function onSend() {
  const body = text.value.trim()
  if (!body) return
  emit('send', body, props.parentTaskId)
  text.value = ''
}

function onFiles(ev: Event) {
  const input = ev.target as HTMLInputElement
  if (!input.files || input.files.length === 0) return
  // Upload hits POST /v1/files once the WUI session token exists. Names only for now.
  const names = [...input.files].map((f) => f.name).join(', ')
  text.value = text.value ? `${text.value}\n${names}` : names
  input.value = ''
}
</script>
