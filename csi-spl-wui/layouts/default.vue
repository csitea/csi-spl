<template>
  <ClientOnly>
    <div class="spool-shell" style="max-width:100%;min-width:0">
      <ChannelSidebar />
      <main class="spool-main">
        <slot />
      </main>
      <ThreadPane />
    </div>
    <template #fallback>
      <div class="login"><p class="muted">Loading Spool…</p></div>
    </template>
  </ClientOnly>
</template>
