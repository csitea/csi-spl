<!-- spec 116 4.3, direction C "Browser and terminal": a command is typed in a
     monochrome terminal (the theme's colours) and lands as a post in the browser's channel, once,
     then still. Phone: the panes stack, terminal on top. Reduced motion:
     both panes in their final state. Fixture strings only. -->
<template>
  <div class="ht" data-test="front-look-hero-c">
    <div class="ht__term">
      <div class="ht__chrome"><i /><i /><i /><span>agent@box: ~/repo</span></div>
      <pre class="ht__screen"><span class="ht__muted">$ go test ./...</span>
<span class="ht__muted">ok   sign-in   1.82s</span>
<span class="ht__prompt">$ </span><span class="ht__typed"><span v-for="(ch, i) in CMD" :key="i" :style="{ '--c': i }">{{ ch }}</span></span><span class="ht__cursor" />
<span class="ht__sent">sent · result · #release-train</span></pre>
    </div>
    <div class="ht__flight" aria-hidden="true"><span class="ht__packet" /></div>
    <div class="ht__browser">
      <div class="ht__chrome ht__chrome--browser"><i /><i /><i /><span class="ht__url">spool · #release-train</span></div>
      <div class="ht__chan">
        <div class="ht__post">
          <span class="ht__av ht__av--person">m</span>
          <div><b>maria</b> <small>09:40</small><p>can we ship once the deploy is through?</p></div>
        </div>
        <div class="ht__post ht__post--new">
          <span class="ht__av">◆</span>
          <div><b>deploy-agent</b> <span class="ht__badge">result</span> <small>09:41</small><p>deploy is green</p></div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
const CMD = 'spool send --kind result --body "deploy is green"'
</script>

<style scoped>
.ht {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 36px minmax(0, 1fr);
  align-items: center;
  min-width: 0;
  text-align: start;
  --ht-type: 2.6s; /* 0.6 s + 49 characters x 0.04 s */
  --ht-land: 3.6s;
}
.ht__term, .ht__browser {
  border-radius: var(--radius-md);
  overflow: hidden;
  min-width: 0;
  box-shadow: 0 24px 60px -30px rgba(0, 0, 0, 0.65);
}
.ht__term { background: var(--color-bg-2); border: 1px solid var(--color-border-strong); color: var(--color-fg); }
.ht__browser { background: var(--color-surface); border: 1px solid var(--color-border-strong); }
.ht__chrome {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 8px 10px;
  font-size: 0.75rem;
  color: var(--color-muted);
  background: var(--color-bg-3);
  border-bottom: 1px solid var(--color-border);
}
.ht__chrome i { width: 9px; height: 9px; border-radius: 50%; background: var(--color-border-strong); }
.ht__chrome span { margin-inline-start: 6px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.ht__chrome--browser { background: var(--color-sidebar); border-bottom-color: var(--color-border); color: var(--color-muted); }
.ht__chrome--browser i { background: var(--color-border-strong); }
.ht__url {
  flex: 1 1 auto;
  padding: 2px 10px;
  border-radius: var(--radius-pill);
  background: var(--color-bg-2);
}
.ht__screen {
  margin: 0;
  padding: 14px 14px 18px;
  font-family: var(--font-mono);
  font-size: 0.8125rem;
  line-height: 1.6;
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  min-height: 9.5em;
}
.ht__muted { color: var(--color-muted); }
.ht__prompt { color: var(--color-ok); }
/* one character at a time, so a long line wraps as it is typed */
.ht__typed > span {
  animation: ht-fade 0.01s linear both;
  animation-delay: calc(0.6s + var(--c) * 0.04s);
}
.ht__cursor {
  display: inline-block;
  width: 0.6em;
  height: 1.1em;
  vertical-align: text-bottom;
  background: var(--color-fg);
  animation: ht-blink 0.9s steps(1) 6;
}
.ht__sent { color: var(--color-ok); animation: ht-fade 0.3s ease-out both; animation-delay: calc(var(--ht-type) + 0.7s); }
.ht__flight { position: relative; height: 2px; background: linear-gradient(90deg, transparent, var(--color-border-strong), transparent); }
.ht__packet {
  position: absolute;
  top: 50%;
  left: 0;
  width: 10px;
  height: 10px;
  margin-top: -5px;
  border-radius: 50%;
  background: var(--color-accent);
  box-shadow: 0 0 12px 3px var(--color-glow);
  opacity: 0;
  animation: ht-fly 0.8s ease-in-out both;
  animation-delay: calc(var(--ht-type) + 0.8s);
}
.ht__chan { padding: 10px; display: grid; gap: 6px; min-height: 9.5em; align-content: end; }
.ht__post { display: flex; gap: 10px; padding: 8px; border-radius: var(--radius-sm); font-size: 0.875rem; color: var(--color-fg); }
.ht__post b { color: var(--color-heading); }
.ht__post small { color: var(--color-muted); }
.ht__post p { margin: 2px 0 0; }
.ht__post--new {
  background: color-mix(in srgb, var(--color-accent) 10%, transparent);
  box-shadow: inset 3px 0 0 var(--color-accent);
  animation: ht-land 0.6s cubic-bezier(0.2, 1.3, 0.4, 1) both;
  animation-delay: var(--ht-land);
}
.ht__av {
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 30px;
  height: 30px;
  border-radius: 50%;
  color: var(--color-on-accent);
  font-size: 0.8rem;
  background: linear-gradient(135deg, var(--color-accent), var(--color-accent-2));
}
.ht__av--person { border-radius: var(--radius-sm); background: linear-gradient(135deg, var(--color-warn), var(--color-danger)); }
.ht__badge {
  font-size: 0.6875rem;
  padding: 0 6px;
  border-radius: var(--radius-pill);
  color: var(--color-ok);
  border: 1px solid color-mix(in srgb, var(--color-ok) 50%, transparent);
}
@keyframes ht-blink { 50% { opacity: 0; } }
@keyframes ht-fade { from { opacity: 0; } to { opacity: 1; } }
@keyframes ht-fly {
  0% { left: 0; opacity: 0; }
  20% { opacity: 1; }
  100% { left: calc(100% - 10px); opacity: 0; }
}
@keyframes ht-land {
  from { opacity: 0; transform: translateX(-16px); }
  to { opacity: 1; transform: none; }
}
/* Phone: the panes stack, terminal on top; the post travels down. */
@media (max-width: 820px) {
  .ht { grid-template-columns: minmax(0, 1fr); grid-template-rows: auto 28px auto; }
  .ht__flight { width: 2px; height: 100%; justify-self: center; background: linear-gradient(180deg, transparent, var(--color-border-strong), transparent); }
  .ht__packet { left: 50%; top: 0; margin: 0 0 0 -5px; animation-name: ht-fly-down; }
  .ht__screen, .ht__chan { min-height: 0; }
  .ht__post:not(.ht__post--new) { display: none; }
}
@keyframes ht-fly-down {
  0% { top: 0; opacity: 0; }
  20% { opacity: 1; }
  100% { top: calc(100% - 10px); opacity: 0; }
}
@media (prefers-reduced-motion: reduce) {
  .ht__typed > span, .ht__cursor, .ht__sent, .ht__post--new { animation: none; }
  .ht__packet { animation: none; opacity: 0; }
}
</style>
