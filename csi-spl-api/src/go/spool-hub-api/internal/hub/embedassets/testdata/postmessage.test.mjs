// Drives loader.js and chat.html's script in node with a fake DOM and
// records every postMessage (specs/121 T202, run by embedassets_test.go).
// Proves: no message text crosses postMessage, each call has the exact
// targetOrigin, a message from another origin or window is ignored, and the
// visitor token sits in the frame's localStorage and travels as
// Authorization: Bearer. T202b: a relink code (#spool-relink=) goes from the
// page's fragment to the iframe's, is redeemed in a request body only, and
// never crosses postMessage, a URL, the storage or a log; the 410 and 409
// answers are shown plainly. Usage: node postmessage.test.mjs <assets dir>
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
const CODE = "CODEMARKAbCdEf0123_-";
const CODE_USED = "CODEMARKused";
const TOKEN_NEW = "tok-1";
const GONE = "This link has expired or was already used. Ask for a new one below.";
const NO_ANSWER = "You can leave your e-mail after our first answer.";

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

// logger stands in for console: every line any asset logs, to prove the
// relink code reaches none.
function logger() {
  const lines = [];
  const rec = (...a) => lines.push(a.map((x) => (typeof x === "string" ? x : JSON.stringify(x))).join(" "));
  return { log: rec, info: rec, warn: rec, error: rec, debug: rec, lines };
}

// history fakes replaceState over loc, keeping hash in step with the URL.
function history(loc) {
  const calls = [];
  return { calls, state: null, replaceState(st, t, url) { calls.push(url); const i = url.indexOf("#"); loc.hash = i < 0 ? "" : url.slice(i); } };
}

function chatWindow(search, ancestor, opts = {}) {
  const html = fs.readFileSync(path.join(dir, "chat.html"), "utf8");
  const code = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const els = {};
  for (const id of ["lines", "status", "form", "text", "close", "email-form", "email", "ask-form", "ask-email"]) els[id] = new El(id);
  const parentPosts = [];
  const parent = { postMessage: (data, target) => parentPosts.push({ data: JSON.parse(JSON.stringify(data)), target }) };
  const reqs = [];
  const staff = [];
  let n = 0;
  const fetch = async (url, init) => {
    reqs.push({ url, ...init });
    const ok = (status, body) => ({ status, ok: status < 300, json: async () => body });
    if (url.endsWith("/visitor") && init.method === "POST") return ok(201, { token: "tok-1", visitor_id: "v", channel: "c", expires_at: "x" });
    if (url.endsWith("/relink/redeem") && init.method === "POST") {
      if (JSON.parse(init.body).code !== CODE) return ok(410, { error: "embed_relink" });
      return ok(201, { token: TOKEN_NEW, visitor_id: "v", channel: "c", expires_at: "x" });
    }
    if (url.endsWith("/relink") && init.method === "POST") return ok(202, { outcome: "accepted" });
    if (init.headers.Authorization !== "Bearer tok-1") return ok(401, {});
    if (url.endsWith("/visitor/email") && init.method === "PUT") {
      if (opts.email409 || !staff.some((m) => !m.mine)) return ok(409, { error: "embed_no_answer" });
      return init.body.includes("@") ? ok(204, null) : ok(400, { error: "bad_request" });
    }
    if (url.endsWith("/messages") && init.method === "POST") {
      staff.push({ msg_id: "m" + n, body: JSON.parse(init.body).body, mine: true, received_at: `2026-10-11T00:00:${String(n++).padStart(2, "0")}Z` });
      return ok(201, { msg_id: "m", received_at: "x" });
    }
    if (url.endsWith("/messages")) return ok(200, { messages: staff.slice() });
    return ok(404, {});
  };
  const listeners = [];
  const intervals = [];
  const ls = opts.ls || storage();
  const loc = { pathname: "/embed/v1/chat", search, hash: opts.hash || "", origin: HUB, ancestorOrigins: ancestor ? [ancestor] : undefined };
  const hist = history(loc);
  const log = logger();
  const win = {
    location: loc, history: hist, console: log,
    parent, localStorage: ls, fetch, URL, URLSearchParams, setInterval: (f) => intervals.push(f),
    addEventListener: (t, f) => t === "message" && listeners.push(f),
    document: { documentElement: { lang: "en" }, getElementById: (id) => els[id], createElement: (t) => new El(t) },
  };
  win.window = win;
  vm.runInNewContext(code, win);
  const send = (data, origin, source = parent) => listeners.forEach((f) => f({ data, origin, source }));
  const staffSays = (body) => staff.push({ msg_id: "s" + n, body, mine: false, received_at: `2026-10-11T00:00:${String(n++).padStart(2, "0")}Z` });
  const tick = async (k = 6) => { for (let i = 0; i < k; i++) intervals.forEach((f) => f()); await flush(); };
  return { els, parentPosts, reqs, ls, loc, hist, log, send, staffSays, tick };
}

// noCode: the relink code is in no postMessage, request URL or header,
// stored value or log line, and left the frame's address.
function noCode(c, who) {
  const where = {
    postMessage: JSON.stringify(c.parentPosts),
    urls: JSON.stringify(c.reqs.map((r) => [r.url, r.headers])),
    storage: JSON.stringify([...c.ls.map]),
    log: c.log.lines.join("\n"),
    address: c.loc.search + c.loc.hash,
  };
  for (const [k, v] of Object.entries(where)) assert.ok(!v.includes("CODEMARK"), `${who}: relink code in ${k}: ${v}`);
}

// chatRelink: a good code becomes the frame's token and the chat loads with
// it; the code went in one redeem body, without the old token.
async function chatRelink() {
  const ls = storage();
  ls.setItem("spl.embed.shop.token", "tok-old");
  const c = chatWindow(`?e=shop&o=${encodeURIComponent(SHOP)}`, SHOP, { hash: `#spool-relink=${CODE}`, ls });
  await flush();
  assert.equal(c.ls.map.get("spl.embed.shop.token"), TOKEN_NEW, "redeemed token not kept");
  const red = c.reqs.filter((r) => r.url === "/v1/embed/shop/relink/redeem");
  assert.equal(red.length, 1, "want one redeem");
  assert.deepEqual(JSON.parse(red[0].body), { code: CODE });
  assert.equal(red[0].headers.Authorization, undefined, "redeem carried a token");
  assert.ok(c.reqs.some((r) => r.url.endsWith("/messages") && r.headers.Authorization === `Bearer ${TOKEN_NEW}`), "chat not loaded with the new token");
  assert.ok(c.els["ask-form"].hidden, "ask form shown with a token");
  noCode(c, "relink 201");
}

// chatRelinkGone: a used code shows the 410 message plainly, keeps no
// token and offers "send me a link".
async function chatRelinkGone() {
  const c = chatWindow(`?e=shop&o=${encodeURIComponent(SHOP)}`, SHOP, { hash: `#spool-relink=${CODE_USED}` });
  await flush();
  assert.equal(c.els.status.textContent, GONE, "410 not shown plainly");
  assert.equal(c.ls.map.get("spl.embed.shop.token"), undefined);
  assert.equal(c.els["ask-form"].hidden, false, "no send-me-a-link after 410");
  noCode(c, "relink 410");
}

// chatEmail: the e-mail field appears after the first answer with its
// purpose; a 409 from the hub is shown plainly; a save hides the field.
async function chatEmail() {
  const html = fs.readFileSync(path.join(dir, "chat.html"), "utf8");
  assert.match(html, /id="email-purpose">[^<]*\bonly to send you a link\b/, "no purpose line by the e-mail field");
  for (const email409 of [true, false]) {
    const c = chatWindow(`?e=shop&o=${encodeURIComponent(SHOP)}`, SHOP, { email409 });
    await flush();
    assert.equal(c.els["ask-form"].hidden, false, "no send-me-a-link without a token");
    c.els.text.value = TEXT_MINE;
    c.els.form.fire("submit");
    await flush();
    assert.ok(c.els["email-form"].hidden, "e-mail offered before the first answer");
    c.staffSays(TEXT_STAFF);
    await c.tick();
    assert.equal(c.els["email-form"].hidden, false, "e-mail not offered after the first answer");
    c.els.email.value = "visitor@example.com";
    c.els["email-form"].fire("submit");
    await flush();
    const put = c.reqs.filter((r) => r.url === "/v1/embed/shop/visitor/email");
    assert.equal(put.length, 1);
    assert.equal(put[0].method, "PUT");
    assert.equal(put[0].headers.Authorization, "Bearer tok-1");
    if (email409) {
      assert.equal(c.els.status.textContent, NO_ANSWER, "409 not shown plainly");
      assert.equal(c.els["email-form"].hidden, false);
    } else {
      assert.ok(c.els["email-form"].hidden, "e-mail field still offered after a save");
    }
    checkPosts(c.parentPosts, SHOP, "chat email");
    assert.ok(!JSON.stringify(c.parentPosts).includes("visitor@"), "e-mail crossed postMessage");
  }
}

// chatAsk: "send me a link" posts the address and the page's language, with
// no token.
async function chatAsk() {
  const c = chatWindow(`?e=shop&o=${encodeURIComponent(SHOP)}`, SHOP);
  await flush();
  c.els["ask-email"].value = "visitor@example.com";
  c.els["ask-form"].fire("submit");
  await flush();
  const ask = c.reqs.filter((r) => r.url === "/v1/embed/shop/relink");
  assert.equal(ask.length, 1);
  assert.deepEqual(JSON.parse(ask[0].body), { email: "visitor@example.com", locale: "en" });
  assert.equal(ask[0].headers.Authorization, undefined, "relink ask carried a token");
  assert.match(c.els.status.textContent, /link is on its way/);
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

function loaderScenario(hash = "") {
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
  const loc = { origin: SHOP, pathname: "/pricing", search: "?a=1", hash };
  const hist = history(loc);
  const log = logger();
  const win = { location: loc, history: hist, console: log, URL, addEventListener: (t, f) => t === "message" && listeners.push(f), document: doc };
  win.window = win;
  vm.runInNewContext(code, win);
  const frame = created.find((e) => e.tag === "iframe");
  const button = created.find((e) => e.tag === "button");
  const badge = created.find((e) => e.tag === "span");
  const plain = `${HUB}/embed/v1/chat?e=shop&o=${encodeURIComponent(SHOP)}`;
  if (hash.includes("spool-relink=")) {
    // The code moves to the iframe's fragment and out of the page's address.
    assert.equal(frame.src, `${plain}#spool-relink=${CODE}`);
    assert.deepEqual(hist.calls, ["/pricing?a=1#x=1"], "page address keeps the relink code");
  } else {
    assert.equal(frame.src, plain);
    assert.deepEqual(hist.calls, []);
  }
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
  const leak = JSON.stringify(framePosts) + log.lines.join("\n") + loc.search + loc.hash;
  assert.ok(!leak.includes("CODEMARK"), `loader: relink code in a postMessage, log or the page address: ${leak}`);
  return framePosts.length;
}

const chatPosts = await chatScenario();
await chatRefusesBadOrigin();
const loaderPosts = loaderScenario();
loaderScenario(`#spool-relink=${CODE}&x=1`);
await chatRelink();
await chatRelinkGone();
await chatEmail();
await chatAsk();
console.log(`ok chat posts=${chatPosts} loader posts=${loaderPosts} relink email ask`);
