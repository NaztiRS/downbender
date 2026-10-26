const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const extension = path.join(__dirname, "../../ChromeExtension");

function background({ safari = false, response = { ok: true }, badgeFailure = false } = {}) {
  const requests = [];
  const listeners = {};
  const event = (name) => ({ addListener(fn) { listeners[name] = fn; } });
  const api = {
    runtime: {
      sendNativeMessage: async (host, message) => {
        requests.push({ host, message });
        return response;
      },
      onInstalled: event("installed"), onStartup: event("startup"), onMessage: event("message"),
    },
    action: {
      setBadgeText: async () => {},
      onClicked: event("toolbar"),
      ...(safari ? {} : { setBadgeBackgroundColor: async () => {
        if (badgeFailure) throw new Error("Badge unavailable");
      } }),
    },
    contextMenus: { removeAll: async () => {}, create() {}, onClicked: event("context") },
  };
  const context = vm.createContext({
    URL, console, setTimeout: () => 0,
    ...(safari ? { browser: api, DownbenderPlatform: { source: "safari", confirmInstallation: false } } : { chrome: api }),
  });
  context.importScripts = (...names) => names.forEach((name) => {
    vm.runInContext(fs.readFileSync(path.join(extension, name), "utf8"), context);
  });
  context.importScripts("background.js");
  return {
    requests, listeners,
    send(message) {
      return new Promise((resolve) => listeners.message({ type: "downbender-enqueue", ...message }, { tab: { id: 1 } }, resolve));
    },
  };
}

test("Safari delivers a single video with Promise APIs and preserves delivery-only status", async () => {
  const host = background({ safari: true, response: { ok: true, confirmed: false } });
  const result = await host.send({ url: "https://www.youtube.com/watch?v=one&list=RDone", source: "active-video-overlay" });
  assert.equal(result.ok, true);
  assert.equal(result.confirmed, false);
  assert.equal(host.requests.length, 1);
  assert.equal(host.requests[0].message.url, "https://www.youtube.com/watch?v=one");
});

test("Safari never runs Chromium installer cleanup", async () => {
  const host = background({ safari: true });
  host.listeners.installed();
  host.listeners.startup();
  await new Promise(setImmediate);
  assert.equal(host.requests.length, 0);
});

test("Chromium retains installation confirmation and confirmed enqueue", async () => {
  const host = background();
  host.listeners.installed();
  await new Promise(setImmediate);
  assert.equal(host.requests[0].message.command, "extension-installed");
  const result = await host.send({ url: "https://example.com/video" });
  assert.equal(result.ok, true);
  assert.notEqual(result.confirmed, false);
  assert.equal(host.requests[1].message.source, "chrome");
});

test("badge failures cannot prevent delivery or turn it into an error", async () => {
  const host = background({ badgeFailure: true });
  const result = await host.send({ url: "https://example.com/video" });
  assert.equal(result.ok, true);
  assert.equal(host.requests.length, 1);
});

test("Safari reports a native rejection to the overlay", async () => {
  const host = background({ safari: true, response: { ok: false, message: "Install Downbender first" } });
  const result = await host.send({ url: "https://example.com/video" });
  assert.equal(result.ok, false);
  assert.equal(result.message, "Install Downbender first");
});

test("Safari rejects unsupported URLs before native messaging", async () => {
  const host = background({ safari: true });
  const result = await host.send({ url: "file:///etc/passwd" });
  assert.equal(result.ok, false);
  assert.equal(host.requests.length, 0);
});
