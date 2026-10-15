<!-- SPL-2027 (owner HUM-10, t1 72898ea2 msgs c4aae6fc, 1689b768): Settings ->
     Appearance -> "Thinking animation", the person's pick of the mark on a
     post that waits for an agent (components/AwaitReply.vue). Kept in this
     browser per signed-in person (useAwaitAnim); each choice shows its own
     running sample. Wraps under the label at phone width. -->
<template>
  <div class="settings__row await-anim-setting" data-test="await-anim-setting">
    <span id="await-anim-label">{{ t('settings.await_anim.label') }}</span>
    <div class="await-anim-setting__opts" role="radiogroup" aria-labelledby="await-anim-label">
      <label
        v-for="id in AWAIT_ANIM_IDS"
        :key="id"
        class="await-anim-setting__opt"
        :class="{ 'await-anim-setting__opt--on': pick === id }"
      >
        <input
          type="radio"
          name="await-anim"
          :value="id"
          :checked="pick === id"
          :data-test="`await-anim-${id}`"
          @change="setPick(id)"
        />
        <AwaitReply state="spin" :anim="id" preview />
        {{ t('settings.await_anim.' + id) }}
      </label>
    </div>
  </div>
</template>

<script setup lang="ts">
import AwaitReply from '~/components/AwaitReply.vue'
import { useAwaitAnim } from '~/composables/useAwaitAnim'
import { AWAIT_ANIM_IDS } from '~/utils/await-reply.mjs'

const { t } = useI18n({ useScope: 'global' })
const { pick, setPick } = useAwaitAnim()
</script>

<style scoped>
.settings__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  min-height: var(--tap, 44px);
}
.await-anim-setting__opts { display: flex; gap: 8px; flex-wrap: wrap; }
.await-anim-setting__opt {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  min-height: var(--tap, 44px);
}
.await-anim-setting__opt--on { color: var(--color-accent); }
</style>
