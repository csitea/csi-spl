<template>
  <div class="login">
    <!-- Full-bleed wallpaper. The drift layer is larger than the viewport and
         clipped here, so the slow pan cannot widen the page. -->
    <div class="login-wallpaper" aria-hidden="true">
      <div class="login-wallpaper__drift" data-test="login-wallpaper"></div>
      <div class="login-wallpaper__drift login-wallpaper__drift--chip" data-test="login-wallpaper-chip"></div>
      <div class="login-wallpaper__drift login-wallpaper__drift--robot" data-test="login-wallpaper-robot"></div>
    </div>
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
  flex: 0 0 auto;
  font-size: 15px;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--color-accent);
  white-space: nowrap;
}
/* The title keeps its full name. The language control gives up width on a
   phone so the two never collide or push the page sideways. */
.login-bar :deep(.lang-switcher) {
  flex: 0 1 16rem;
  width: 100%;
  min-width: 0;
  max-width: 16rem;
}
.login-bar :deep(.lang-switcher__combobox) {
  width: 100%;
}
.login-body {
  position: relative;
  z-index: 1;
  flex: 1;
  display: grid;
  place-items: center;
  padding: 24px;
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
}
/* The bar stays a solid strip. The picture shows in the field around the card. */
.login-wallpaper {
  position: fixed;
  inset: 0;
  z-index: 0;
  overflow: hidden;
  pointer-events: none;
}
.login-wallpaper__drift {
  position: absolute;
  inset: -8%;
  background: #060912 url('/login-wallpaper.webp') center / cover no-repeat;
  animation: login-wallpaper-drift 46s ease-in-out infinite alternate, login-wallpaper-hold 96s ease-in-out infinite;
}
.login-wallpaper__drift--chip {
  background-image: url('/login-wallpaper-chip.webp');
  animation: login-wallpaper-drift 54s ease-in-out infinite alternate-reverse, login-wallpaper-hold-b 96s ease-in-out infinite;
}
.login-wallpaper__drift--robot {
  background-image: url('/login-wallpaper-robot.webp');
  animation: login-wallpaper-drift 50s ease-in-out infinite alternate, login-wallpaper-hold-c 96s ease-in-out infinite;
}
@keyframes login-wallpaper-drift {
  from { transform: translate3d(-1.25%, -0.8%, 0) scale(1.06); }
  to { transform: translate3d(1.25%, 0.9%, 0) scale(1.1); }
}
/* Three pictures in turn. The fades overlap so the field never goes empty. */
@keyframes login-wallpaper-hold {
  0%, 28% { opacity: 1; }
  36%, 92% { opacity: 0; }
  100% { opacity: 1; }
}
@keyframes login-wallpaper-hold-b {
  0%, 28% { opacity: 0; }
  36%, 61% { opacity: 1; }
  69%, 100% { opacity: 0; }
}
@keyframes login-wallpaper-hold-c {
  0%, 61% { opacity: 0; }
  69%, 94% { opacity: 1; }
  100% { opacity: 0; }
}
@media (prefers-reduced-motion: reduce) {
  .login-wallpaper__drift {
    animation: none;
    transform: scale(1.06);
  }
  .login-wallpaper__drift--chip,
  .login-wallpaper__drift--robot {
    opacity: 0;
  }
}
</style>
