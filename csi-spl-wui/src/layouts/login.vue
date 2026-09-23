<template>
  <div class="login">
    <!-- spec 021: the language switcher lives in the frame's header, the
         same end of the bar the app shell uses. -->
    <header class="login-bar" data-test="login-bar">
      <span class="login-bar__title" data-test="login-bar-title">{{ title }}</span>
      <LanguageSwitcher />
    </header>
    <div class="login-body">
      <slot />
    </div>
  </div>
</template>

<script setup lang="ts">
import LanguageSwitcher from '@/components/LanguageSwitcher.vue'
import { loginBarTitle } from '~/utils/login-title.mjs'

const config = useRuntimeConfig()
const title = loginBarTitle(config.public.envName, import.meta.dev)
</script>

<style scoped>
.login {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  justify-content: flex-start;
  padding: 0;
}
.login-bar {
  position: sticky;
  top: 0;
  z-index: var(--z-sticky, 40);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: var(--top-bar-h);
  padding: 4px 12px;
  background: var(--color-sidebar);
  border-bottom: 1px solid var(--color-border);
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  flex-shrink: 0;
}
.login-bar__title {
  font-size: 15px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--color-accent);
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.login-body {
  flex: 1;
  display: grid;
  place-items: center;
  padding: 24px;
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
}
</style>
