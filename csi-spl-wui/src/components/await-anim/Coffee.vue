<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a cup of coffee, its steam rising while the agent thinks.
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <g fill="none" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M2.6 8h8.4v3.4a3 3 0 0 1-3 3H5.6a3 3 0 0 1-3-3zM11 9h1.2a1.6 1.6 0 0 1 0 3.2H11" />
      <path class="await-coffee__steam" d="M4.6 6.2c-.8-1 .8-1.8 0-2.8" />
      <path class="await-coffee__steam await-coffee__steam--2" d="M6.8 6.2c-.8-1 .8-1.8 0-2.8" />
      <path class="await-coffee__steam await-coffee__steam--3" d="M9 6.2c-.8-1 .8-1.8 0-2.8" />
    </g>
  </svg>
</template>

<style scoped>
.await-coffee__steam { opacity: 0.6; }
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-coffee__steam { animation: await-coffee 1.8s ease-out infinite; }
  .await-reply--spin .await-coffee__steam--2 { animation-delay: 0.3s; }
  .await-reply--spin .await-coffee__steam--3 { animation-delay: 0.6s; }
}
@keyframes await-coffee {
  0% { opacity: 0; transform: translateY(1.5px); }
  40% { opacity: 1; }
  100% { opacity: 0; transform: translateY(-2.5px); }
}
</style>
