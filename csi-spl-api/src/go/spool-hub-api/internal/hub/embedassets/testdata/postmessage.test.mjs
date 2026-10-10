// Drives loader.js and chat.html's script in node with a fake DOM and
// records every postMessage (specs/121 T202, run by embedassets_test.go).
// Proves: no message text crosses postMessage, each call has the exact
// targetOrigin, a message from another origin or window is ignored, and the
// visitor token sits in the frame's localStorage and travels as
// Authorization: Bearer. Usage: node postmessage.test.mjs <assets dir>
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import vm from "node:vm";

const dir = process.argv[2];
const HUB = "https://hub.example.test";
const SHOP = "https://shop.example.com";
const EVIL = "https://evil.example.net";
const TEXT_MINE = "TEXTMARK visitor question";
const TEXT_STAFF = "TEXTMARK staff answer";
const KEYS = new Set(["spl", "ev", "n"]);
const EVENTS = new Set(["open", "close", "unread"]);

const flush = async () => { for (let i = 0; i < 20; i++) await new Promise((r) => setImmediate(r)); };

class El {
  constructor(tag) { this.tag = tag; this.children = []; this.attrs = {}; this.on = {}; this.style = {}; this.textContent = ""; this.value = ""; }
  appendChild(c) { this.children.push(c); return c; }
  setAttribute(k, v) { this.attrs[k] = String(v); }
  getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; }
  addEventListener(t, f) { (this.on[t] ||= []).push(f); }
  fire(t, e = {}) { for (const f of this.on[t] || []) f({ preventDefault() {}, ...e }); }
  focus() {}
  requestSubmit() { this.fire("submit"); }
}

function storage() {
  const m = new Map();
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, String(v)), removeItem: (k) => m.delete(k), map: m };
}

// checkPosts: every recorded call is a UI event, to the exact origin, with
// no text: the core Done item of T202.
function checkPosts(posts, origin, who) {
  for (const p of posts) {
    assert.equal(p.target, origin, `${who}: targetOrigin ${p.target}`);
    const s = JSON.stringify(p.data);
    assert.ok(!s.includes("TEXTMARK"), `${who}: message text crossed postMessage: ${s}`);
    for (const k of Object.keys(p.data)) assert.ok(KEYS.has(k), `${who}: key ${k} in ${s}`);
    assert.equal(p.data.spl, 1);
    assert.ok(EVENTS.has(p.data.ev), `${who}: event ${p.data.ev}`);
    if ("n" in p.data) assert.equal(typeof p.data.n, "number");
  }
}

function chatWindow(search, ancestor) {
  const html = fs.readFileSync(path.join(dir, "chat.html"), "utf8");
  const code = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const els = {};
  for (const id of ["lines", "status", "form", "text", "close"]) els[id] = new El(id);
  const parentPosts = [];
  const parent = { postMessage: (data, target) => parentPosts.push({ data: JSON.parse(JSON.stringify(data)), target }) };
  const reqs = [];
  const staff = [];
  let n = 0;
  const fetch = async (url, init) => {
    reqs.push({ url, ...init });
    const ok = (status, body) => ({ status, ok: status < 300, json: async () => body });
    if (url.endsWith("/visitor") && init.method === "POST") return ok(201, { token: "tok-1", visitor_id: "v", channel: "c", expires_at: "x" });
    if (init.headers.Authorization !== "Bearer tok-1") return ok(401, {});
    if (url.endsWith("/messages") && init.method === "POST") {
      staff.push({ msg_id: "m" + n, body: JSON.parse(init.body).body, mine: true, received_at: `2026-10-11T00:00:${String(n++).padStart(2, "0")}Z` });
      return ok(201, { msg_id: "m", received_at: "x" });
    }
    if (url.endsWith("/messages")) return ok(200, { messages: staff.slice() });
    return ok(404, {});
  };
  const listeners = [];
  const intervals = [];
  const ls = storage();
  const win = {
    location: { search, origin: HUB, ancestorOrigins: ancestor ? [ancestor] : undefined },
    parent, localStorage: ls, fetch, URL, URLSearchParams, setInterval: (f) => intervals.push(f),
    addEventListener: (t, f) => t === "message" && listeners.push(f),
    document: { getElementById: (id) => els[id], createElement: (t) => new El(t) },
  };
  win.window = win;
  vm.runInNewContext(code, win);
  const send = (data, origin, source = parent) => listeners.forEach((f) => f({ data, origin, source }));
  const staffSays = (body) => staff.push({ msg_id: "s" + n, body, mine: false, received_at: `2026-10-11T00:00:${String(n++).padStart(2, "0")}Z` });
  const tick = async (k = 6) => { for (let i = 0; i < k; i++) intervals.forEach((f) => f()); await flush(); };
  return { els, parentPosts, reqs, ls, send, staffSays, tick };
}

async function chatScenario() {
  const c = chatWindow(`?e=shop&o=${encodeURIComponent(SHOP)}`, SHOP);
  await flush();
  c.send({ spl: 1, ev: "open" }, SHOP);
  c.els.text.value = TEXT_MINE;
  c.els.form.fire("submit");
  await flush();
  c.staffSays(TEXT_STAFF);
  await c.tick();
  // Rendered inside the frame, as text.
  assert.ok(c.els.lines.children.some((li) => li.textContent === TEXT_STAFF), "staff line not rendered");
  // Close from the frame's own button, then two more staff lines arrive.
  c.els.close.fire("click");
  c.staffSays(TEXT_STAFF + "-2");
  c.staffSays(TEXT_STAFF + "-3");
  await c.tick();
  // A spoofed "open" from another origin, or from another window, must not
  // mark them seen.
  c.send({ spl: 1, ev: "open" }, EVIL);
  c.send({ spl: 1, ev: "open" }, SHOP, { postMessage() {} });
  c.staffSays(TEXT_STAFF + "-4");
  await c.tick();

  checkPosts(c.parentPosts, SHOP, "chat");
  const evs = c.parentPosts.map((p) => p.data.ev + (p.data.n === undefined ? "" : p.data.n));
  assert.ok(evs.includes("close"), `no close event: ${evs}`);
  assert.ok(evs.includes("unread2"), `no unread 2 after close: ${evs}`);
  assert.ok(evs.includes("unread3"), `spoofed open reset unread (want unread3): ${evs}`);

  // Token: the frame's own localStorage, sent as Bearer, never a cookie.
  assert.equal(c.ls.map.get("spl.embed.shop.token"), "tok-1");
  const authed = c.reqs.filter((r) => !r.url.endsWith("/visitor"));
  assert.ok(authed.length > 0);
  for (const r of authed) {
    assert.equal(r.headers.Authorization, "Bearer tok-1", r.url);
    assert.equal(r.credentials, "omit", r.url);
    assert.ok(r.url.startsWith("/v1/embed/shop/"), r.url);
  }
  return c.parentPosts.length;
}

async function chatRefusesBadOrigin() {
  for (const [o, ancestor] of [["*", undefined], [`${SHOP}/path`, undefined], ["http://shop.example.com", undefined], [SHOP, EVIL]]) {
    const c = chatWindow(`?e=shop&o=${encodeURIComponent(o)}`, ancestor);
    await flush();
    c.send({ spl: 1, ev: "open" }, o);
    c.els.close.fire("click");
    c.staffSays(TEXT_STAFF);
    await c.tick();
    assert.equal(c.parentPosts.length, 0, `o=${o} ancestor=${ancestor}: posted ${JSON.stringify(c.parentPosts)}`);
  }
}

function loaderScenario() {
  const code = fs.readFileSync(path.join(dir, "loader.js"), "utf8");
  const framePosts = [];
  const created = [];
  const body = new El("body");
  const listeners = [];
  const script = new El("script");
  script.src = `${HUB}/embed/v1/loader.js`;
  script.setAttribute("data-embed", "shop");
  const doc = {
    currentScript: script, body,
    getElementById: () => null,
    addEventListener() {},
    createElement: (t) => {
      const e = new El(t);
      if (t === "iframe") e.contentWindow = { postMessage: (data, target) => framePosts.push({ data: JSON.parse(JSON.stringify(data)), target }) };
      created.push(e);
      return e;
    },
  };
  const win = { location: { origin: SHOP }, URL, addEventListener: (t, f) => t === "message" && listeners.push(f), document: doc };
  win.window = win;
  vm.runInNewContext(code, win);
  const frame = created.find((e) => e.tag === "iframe");
  const button = created.find((e) => e.tag === "button");
  const badge = created.find((e) => e.tag === "span");
  assert.equal(frame.src, `${HUB}/embed/v1/chat?e=shop&o=${encodeURIComponent(SHOP)}`);
  const send = (data, origin, source = frame.contentWindow) => listeners.forEach((f) => f({ data, origin, source }));

  send({ spl: 1, ev: "unread", n: 3, body: TEXT_STAFF }, HUB);
  assert.equal(badge.textContent, "3");
  assert.ok(!JSON.stringify(created.map((e) => [e.textContent, e.attrs])).includes("TEXTMARK"), "loader put text into the page");
  send({ spl: 1, ev: "unread", n: 9 }, EVIL);
  send({ spl: 1, ev: "unread", n: 9 }, HUB, {});
  assert.equal(badge.textContent, "3", "unread from another origin or window was taken");
  button.fire("click");
  assert.equal(frame.style.display, "block");
  send({ spl: 1, ev: "close" }, EVIL);
  assert.equal(frame.style.display, "block", "close from another origin was taken");
  send({ spl: 1, ev: "close" }, HUB);
  assert.equal(frame.style.display, "none");
  button.fire("click");
  button.fire("click");
  checkPosts(framePosts, HUB, "loader");
  assert.deepEqual(framePosts.map((p) => p.data.ev), ["open", "open", "close"]);
  return framePosts.length;
}

const chatPosts = await chatScenario();
await chatRefusesBadOrigin();
const loaderPosts = loaderScenario();
console.log(`ok chat posts=${chatPosts} loader posts=${loaderPosts}`);
