<!-- SPL-2113 (owner HUM-10, t1 3aa9fac2): a robot dancing: it sways on its feet, its arms go up and down in turn, a note floats away (owner msg c33a028e).
     One drawing of the "thinking" mark (components/AwaitReply.vue), its own
     lazy chunk. It moves only while the mark spins and motion is welcome. -->
<template>
  <svg class="await-reply__glyph" viewBox="0 0 16 16" width="20" height="20" aria-hidden="true" focusable="false">
    <path class="await-dance__note" d="M13 4.6V1.4l2.2-.6v2.6" fill="none" stroke="currentColor" stroke-width=".9" stroke-linecap="round" stroke-linejoin="round" />
    <g class="await-dance__body" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
      <path d="M8 2.8V1.6" />
      <rect x="5" y="2.8" width="6" height="4" rx="1.2" />
      <rect x="5.8" y="7.4" width="4.4" height="3.8" rx=".8" />
      <path class="await-dance__arm await-dance__arm-l" d="M5.8 8.4 3.4 6.4" />
      <path class="await-dance__arm await-dance__arm-r" d="m10.2 8.4 2.4-2" />
      <path d="M7 11.2 6.2 14.6M9 11.2l.8 3.4" />
    </g>
    <circle class="await-dance__eye" cx="6.9" cy="4.8" r=".7" fill="currentColor" />
    <circle class="await-dance__eye" cx="9.1" cy="4.8" r=".7" fill="currentColor" />
    <circle cx="13" cy="4.7" r=".8" class="await-dance__note" fill="currentColor" />
  </svg>
</template>

<style scoped>
.await-dance__note { opacity: 0; }
@media (prefers-reduced-motion: no-preference) {
  .await-reply--spin .await-dance__body,
  .await-reply--spin .await-dance__eye {
    animation: await-dancing-robot 0.8s ease-in-out infinite alternate;
    transform-box: view-box;
    transform-origin: 8px 14.6px;
  }
  .await-reply--spin .await-dance__arm {
    animation: await-dancing-robot-arm 0.4s ease-in-out infinite alternate;
    transform-box: view-box;
  }
  .await-reply--spin .await-dance__arm-l { transform-origin: 5.8px 8.4px; }
  .await-reply--spin .await-dance__arm-r { transform-origin: 10.2px 8.4px; animation-direction: alternate-reverse; }
  .await-reply--spin .await-dance__note { animation: await-dancing-robot-note 1.6s ease-out infinite; }
}
@keyframes await-dancing-robot {
  from { transform: rotate(-12deg); }
  to { transform: rotate(12deg); }
}
@keyframes await-dancing-robot-arm {
  from { transform: rotate(0deg); }
  to { transform: rotate(-70deg); }
}
@keyframes await-dancing-robot-note {
  0% { opacity: 0; transform: translate(0, 1px); }
  30% { opacity: 1; }
  100% { opacity: 0; transform: translate(1px, -3px); }
}
</style>
