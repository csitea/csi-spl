<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a pendulum swinging from side to side.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <path d="M4.5 1.2h7" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
    <g class="await-pendulum__arm">
      <path d="M8 1.2v9.2" fill="none" stroke="currentColor" stroke-width="1.1" stroke-linecap="round" />
      <circle cx="8" cy="12.2" r="2.2" fill="currentColor" />
    </g>
  </svg>
</template>

<style scoped>
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-pendulum__arm {
    animation: await-pendulum 0.75s ease-in-out infinite alternate;
    transform-box: view-box;
    transform-origin: 8px 1.2px;
  }
}
@keyframes await-pendulum {
  from { transform: rotate(-32deg); }
  to { transform: rotate(32deg); }
}
</style>
