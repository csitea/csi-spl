<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a brain thinking too hard: it swells, pops in a burst, comes back (SPL-2027).
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <g class="await-brain__head" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M8 3.4c-.9-1-2.8-.9-3.4.4-1.4.1-2.3 1.3-1.9 2.6-1 .8-1 2.4.1 3.1-.1 1.4 1 2.5 2.4 2.3.6 1 2.1 1.2 2.8.3.7.9 2.2.7 2.8-.3 1.4.2 2.5-.9 2.4-2.3 1.1-.7 1.1-2.3.1-3.1.4-1.3-.5-2.5-1.9-2.6-.6-1.3-2.5-1.4-3.4-.4z" />
      <path d="M8 3.4v8.9M5.4 6.3c.9.1 1.5.7 1.6 1.5M10.6 6.3c-.9.1-1.5.7-1.6 1.5M5.6 9.8c.7-.5 1.6-.4 2.1.2M10.4 9.8c-.7-.5-1.6-.4-2.1.2" stroke-width="1" />
    </g>
    <path class="await-brain__burst" d="M8 .3v1.6M8 14.1v1.6M.3 8h1.6M14.1 8h1.6M2.6 2.6l1.1 1.1M12.3 12.3l1.1 1.1M13.4 2.6l-1.1 1.1M3.7 12.3l-1.1 1.1" fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
  </svg>
</template>

<style scoped>
.await-brain__burst { opacity: 0; }
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-brain__head {
    animation: await-brain 2.4s ease-in infinite;
    transform-box: view-box;
    transform-origin: 8px 8px;
  }
  .await-reply--spin .await-brain__burst {
    animation: await-brain-burst 2.4s ease-out infinite;
    transform-box: view-box;
    transform-origin: 8px 8px;
  }
}
/* swell, swell harder, pop (gone), regrow */
@keyframes await-brain {
  0% { transform: scale(0.85); opacity: 1; }
  55% { transform: scale(1.1); opacity: 1; }
  68% { transform: scale(1.25); opacity: 1; }
  72% { transform: scale(1.4); opacity: 0; }
  84% { transform: scale(0.3); opacity: 0; }
  100% { transform: scale(0.85); opacity: 1; }
}
@keyframes await-brain-burst {
  0%, 68% { transform: scale(0.6); opacity: 0; }
  74% { transform: scale(1); opacity: 1; }
  86%, 100% { transform: scale(1.2); opacity: 0; }
}
</style>
