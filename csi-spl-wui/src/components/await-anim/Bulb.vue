<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a light bulb: an idea lights up, glows, fades, lights again.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <path class="await-bulb__glow" d="M8 2.6a4 4 0 0 0-2.4 7.2c.5.4.8.9.8 1.5h3.2c0-.6.3-1.1.8-1.5A4 4 0 0 0 8 2.6z" fill="currentColor" />
    <g fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M8 2.6a4 4 0 0 0-2.4 7.2c.5.4.8.9.8 1.5h3.2c0-.6.3-1.1.8-1.5A4 4 0 0 0 8 2.6zM6.6 13.2h2.8M7.2 15h1.6" />
      <path class="await-bulb__rays" d="M8 .2v1M2.3 2.4l.7.7M13.7 2.4l-.7.7M.6 7.2h1M14.4 7.2h1" />
    </g>
  </svg>
</template>

<style scoped>
.await-bulb__glow { opacity: 0.15; }
.await-bulb__rays { opacity: 0; }
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-bulb__glow { animation: await-bulb 2s ease-in-out infinite; }
  .await-reply--spin .await-bulb__rays { animation: await-bulb-rays 2s ease-in-out infinite; }
}
@keyframes await-bulb {
  0%, 20% { opacity: 0.15; }
  40%, 70% { opacity: 0.85; }
  100% { opacity: 0.15; }
}
@keyframes await-bulb-rays {
  0%, 30% { opacity: 0; }
  45%, 65% { opacity: 1; }
  80%, 100% { opacity: 0; }
}
</style>
