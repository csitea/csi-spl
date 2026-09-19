<template>
  <div class="msg-body">
    <template v-for="(b, i) in blocks" :key="i">
      <figure
        v-if="b.type === 'code'"
        class="code-block"
        :aria-label="b.lang ? t('code.block_label_lang', { lang: b.lang }) : t('code.block_label')"
      >
        <figcaption class="code-head">
          <span v-if="b.lang" class="code-lang">{{ b.lang }}</span>
          <button
            type="button"
            class="code-copy"
            data-testid="code-copy"
            :aria-label="copiedIdx === i ? t('code.copied') : t('code.copy')"
            @click="copy(i, b.text)"
          >
            {{ copiedIdx === i ? t('code.copied') : t('code.copy') }}
          </button>
        </figcaption>
        <pre class="code-pre" tabindex="0"><code>{{ b.text }}</code></pre>
      </figure>
      <p v-else class="msg-para">
        <template v-for="(p, j) in b.parts" :key="j">
          <code v-if="p.type === 'inline'" class="code-inline">{{ p.text }}</code>
          <strong v-else-if="p.type === 'strong'">{{ p.text }}</strong>
          <span v-else-if="p.type === 'mention'" class="mention">{{ p.text }}</span>
          <template v-else>{{ p.text }}</template>
        </template>
      </p>
    </template>
    <span class="sr-only" aria-live="polite">{{ copiedIdx >= 0 ? t('code.copied') : '' }}</span>
  </div>
</template>

<script setup lang="ts">
import { parseBody } from '~/utils/code-blocks.mjs'

/* Slack-style ``` blocks and `inline code`; every string is text-interpolated, never markup. */
const props = defineProps<{ body: string }>()
const { t } = useI18n({ useScope: 'global' })
const blocks = computed(() => parseBody(props.body))
const copiedIdx = ref(-1)
let timer: ReturnType<typeof setTimeout> | undefined

async function writeClipboard(text: string) {
  try {
    await navigator.clipboard.writeText(text)
    return
  } catch {
    /* insecure context or denied: the selection fallback below */
  }
  const ta = document.createElement('textarea')
  ta.value = text
  ta.setAttribute('readonly', '')
  ta.className = 'sr-only'
  document.body.appendChild(ta)
  ta.select()
  document.execCommand('copy')
  ta.remove()
}

async function copy(i: number, text: string) {
  await writeClipboard(text)
  copiedIdx.value = i
  clearTimeout(timer)
  timer = setTimeout(() => { copiedIdx.value = -1 }, 1800)
}
onUnmounted(() => clearTimeout(timer))
</script>

<style scoped>
.msg-para {
  margin: 0;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
}
.msg-para + .msg-para,
.code-block + .msg-para { margin-top: 4px; }
.code-inline {
  font-family: var(--font-mono);
  background: var(--color-bg-2);
  padding: 1px 4px;
  border-radius: 4px;
  font-size: 12px;
  white-space: pre-wrap;
}
.code-block {
  margin: 4px 0;
  border: 1px solid var(--color-border);
  border-radius: var(--radius);
  background: var(--color-bg-2);
  max-width: 100%;
  min-width: 0;
  overflow: hidden;
}
.code-head {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 2px 4px 0 10px;
  min-width: 0;
}
.code-lang {
  font-family: var(--font-mono);
  font-size: 11px;
  color: var(--color-muted);
  overflow-wrap: anywhere;
  min-width: 0;
}
.code-copy {
  margin-left: auto;
  background: transparent;
  border: 1px solid transparent;
  border-radius: 6px;
  color: var(--color-muted);
  font-size: 12px;
  padding: 2px 8px;
  cursor: pointer;
}
.code-copy:hover,
.code-copy:focus-visible {
  color: var(--color-fg);
  border-color: var(--color-border);
}
.code-pre {
  margin: 0;
  padding: 4px 10px 8px;
  font-family: var(--font-mono);
  font-size: 12px;
  line-height: 1.5;
  white-space: pre;
  overflow-wrap: normal;
  overflow-x: auto;
  max-width: 100%;
  min-width: 0;
}
.code-pre:focus-visible { outline: 2px solid var(--color-accent); outline-offset: -2px; }
.code-pre code { font-family: inherit; background: none; padding: 0; font-size: inherit; }
</style>
