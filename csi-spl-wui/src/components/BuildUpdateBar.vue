<!-- SPL-1006: "A new version is available - Reload". Shown only while the
     page holds something a reload would lose (a draft, an open dialog, a
     send in flight); an idle tab reloads by itself and never sees it. Small
     and non-blocking: nothing behind it is covered but its own strip, and
     it is in the EAGER bundle on purpose - after a deploy the old build's
     lazy chunks are gone from the server, so a lazy bar could never load. -->
<template>
  <div
    v-if="state.prompt"
    class="build-bar"
    role="status"
    aria-live="polite"
    data-test="build-update-bar"
    data-build-watch-ignore
  >
    <span class="build-bar__text">{{ t('build.new_version') }}</span>
    <button type="button" class="btn build-bar__reload" data-test="build-update-reload" @click="reload">
      {{ t('build.reload') }}
    </button>
  </div>
</template>

<script setup lang="ts">
import { reloadForBuild, useBuildWatch } from '~/composables/useBuildWatch'

const { t } = useI18n()
const state = useBuildWatch()
function reload() { reloadForBuild(state.value.live) }
</script>

<style scoped>
.build-bar {
  position: fixed;
  top: calc(var(--top-bar-h) + 0.5rem);
  /* centred by auto margins, not left:50% + translate: that caps the
     shrink-to-fit width at half the screen and wraps the text on phones */
  left: 0;
  right: 0;
  margin-inline: auto;
  width: fit-content;
  z-index: var(--z-banner);
  display: flex;
  align-items: center;
  gap: 0.75rem;
  max-width: calc(100vw - 2rem);
  box-sizing: border-box;
  padding: 0.375rem 0.375rem 0.375rem 0.875rem;
  border: 1px solid var(--color-accent);
  border-radius: var(--radius-sm);
  background: color-mix(in srgb, var(--color-accent) 12%, var(--color-surface));
  color: var(--color-fg);
  box-shadow: var(--focus-3d);
  font-size: 0.875rem;
}
.build-bar__text { min-width: 0; overflow-wrap: anywhere; }
.build-bar__reload { flex: none; min-height: 2.25rem; }
@media (pointer: coarse) {
  .build-bar__reload { min-height: 2.75rem; }
}
</style>
