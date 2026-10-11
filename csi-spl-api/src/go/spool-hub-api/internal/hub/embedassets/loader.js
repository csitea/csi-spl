/*
 * Spool embed loader (specs/121 section 5, T202).
 *
 * A customer page includes it with one tag:
 *   <script src="https://<hub host>/embed/v1/loader.js" data-embed="<embed-id>" async></script>
 * It draws a launcher button and frames /embed/v1/chat?e=<embed-id> from the
 * hub. The page never sees the visitor token or a message: the two sides
 * exchange UI events only (open, close, unread count) through postMessage,
 * each with an exact targetOrigin and an event.origin check.
 *
 * A relink mail (T206) opens this page with #spool-relink=<code>: the loader
 * takes the code out of the page's address and hands it to the iframe in the
 * iframe's own fragment, which no server receives, never through postMessage
 * (T202b). The chat page redeems it.
 */
(function () {
  "use strict";
  var script = document.currentScript;
  if (!script || !script.src) return;
  var hub = new URL(script.src).origin;
  var embed = script.getAttribute("data-embed") || "";
  if (!/^[a-z0-9][a-z0-9-]{2,63}$/.test(embed)) return;
  var KEY = "spl-embed-" + embed;
  if (document.getElementById(KEY)) return;

  // The only events either side sends; anything else is dropped.
  var EVENTS = { open: 1, close: 1, unread: 1 };

  // uiEvent is the one shape a message to the iframe may have: no text.
  function uiEvent(ev) {
    if (!EVENTS[ev] || ev === "unread") throw new Error("embed: not a UI event");
    return { spl: 1, ev: ev };
  }

  // takeRelink removes spool-relink=<code> from the page's fragment, so it
  // is neither bookmarked nor redeemed twice, and returns the code ("" when
  // there is none or it is not base64url).
  function takeRelink() {
    var parts = (window.location.hash || "").replace(/^#/, "").split("&");
    var code = "";
    var rest = parts.filter(function (kv) {
      if (kv.indexOf("spool-relink=") !== 0) return kv !== "";
      code = kv.slice("spool-relink=".length);
      return false;
    });
    if (!code) return "";
    try {
      var l = window.location;
      window.history.replaceState(window.history.state, "",
        l.pathname + l.search + (rest.length ? "#" + rest.join("&") : ""));
    } catch (err) { /* no history API: the code stays in the address */ }
    return /^[A-Za-z0-9_-]{1,256}$/.test(code) ? code : "";
  }
  var relink = takeRelink();

  var frame = document.createElement("iframe");
  frame.id = KEY;
  frame.title = "Chat";
  frame.src = hub + "/embed/v1/chat?e=" + encodeURIComponent(embed) +
    "&o=" + encodeURIComponent(window.location.origin) +
    (relink ? "#spool-relink=" + relink : "");
  frame.setAttribute("allow", "");
  frame.style.cssText = "position:fixed;right:16px;bottom:88px;width:360px;max-width:calc(100vw - 32px);" +
    "height:520px;max-height:calc(100vh - 120px);border:0;border-radius:12px;" +
    "box-shadow:0 8px 32px rgba(0,0,0,.25);z-index:2147483646;background:#fff;display:none";

  var button = document.createElement("button");
  button.type = "button";
  button.setAttribute("aria-label", "Open chat");
  button.setAttribute("aria-expanded", "false");
  button.style.cssText = "position:fixed;right:16px;bottom:16px;width:56px;height:56px;border:0;" +
    "border-radius:50%;background:#2563eb;color:#fff;font:600 24px/56px sans-serif;cursor:pointer;" +
    "box-shadow:0 4px 16px rgba(0,0,0,.25);z-index:2147483647;padding:0";
  button.textContent = "?";
  var badge = document.createElement("span");
  badge.style.cssText = "position:absolute;top:-4px;right:-4px;min-width:20px;height:20px;padding:0 5px;" +
    "border-radius:10px;background:#dc2626;color:#fff;font:600 12px/20px sans-serif;display:none";
  button.appendChild(badge);

  var open = false;
  function toFrame(ev) {
    if (frame.contentWindow) frame.contentWindow.postMessage(uiEvent(ev), hub);
  }
  function setOpen(on, tell) {
    open = on;
    frame.style.display = on ? "block" : "none";
    button.setAttribute("aria-expanded", on ? "true" : "false");
    button.setAttribute("aria-label", on ? "Close chat" : "Open chat");
    if (on) setUnread(0);
    if (tell) toFrame(on ? "open" : "close");
  }
  function setUnread(n) {
    badge.textContent = n > 99 ? "99+" : String(n);
    badge.style.display = n > 0 && !open ? "block" : "none";
  }
  button.addEventListener("click", function () { setOpen(!open, true); });

  window.addEventListener("message", function (e) {
    if (e.origin !== hub || e.source !== frame.contentWindow) return;
    var d = e.data;
    if (!d || d.spl !== 1 || !EVENTS[d.ev]) return;
    if (d.ev === "close") setOpen(false, false);
    else if (d.ev === "open") setOpen(true, false);
    else if (typeof d.n === "number" && d.n >= 0) setUnread(Math.floor(d.n));
  });

  function mount() {
    document.body.appendChild(frame);
    document.body.appendChild(button);
  }
  if (document.body) mount();
  else document.addEventListener("DOMContentLoaded", mount);
})();
