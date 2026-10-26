const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const { prepareSafariResources } = require("../../scripts/prepare-safari-extension.js");

test("the packaged Safari worker uses the shared implementation without Chrome-only install hooks", async (t) => {
  const destination = fs.mkdtempSync(path.join(os.tmpdir(), "downbender-safari-test-"));
  t.after(() => fs.rmSync(destination, { recursive: true, force: true }));
  prepareSafariResources(destination);
  const manifest = JSON.parse(fs.readFileSync(path.join(destination, "manifest.json")));
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.name, "Downbender");
  assert.equal(manifest.key, undefined);
  assert.equal(manifest.incognito, undefined);
  assert.ok(manifest.permissions.includes("nativeMessaging"));
  assert.equal(manifest.browser_specific_settings.safari.strict_min_version, "26.0");
  const chromeManifest = require("../../ChromeExtension/manifest.json");
  assert.deepEqual(manifest.content_scripts, chromeManifest.content_scripts);
  assert.equal(manifest.version, chromeManifest.version);
  for (const entry of manifest.content_scripts) {
    for (const file of entry.js) assert.ok(fs.existsSync(path.join(destination, file)));
  }
  for (const icon of Object.values(manifest.icons)) assert.ok(fs.existsSync(path.join(destination, icon)));

  const listeners = {};
  const requests = [];
  const event = (key) => ({ addListener(fn) { listeners[key] = fn; } });
  const context = vm.createContext({ URL, setTimeout: () => 0, browser: {
    runtime: {
      onInstalled: event("install"), onStartup: event("startup"), onMessage: event("message"),
      sendNativeMessage: async (_, message) => { requests.push(message); return { ok: true, confirmed: false }; },
    },
    action: { setBadgeText: async () => {}, onClicked: event("click") },
    contextMenus: { removeAll: async () => {}, create() {}, onClicked: event("context") },
  } });
  context.importScripts = (...files) => files.forEach((file) => {
    vm.runInContext(fs.readFileSync(path.join(destination, file), "utf8"), context);
  });
  context.importScripts(manifest.background.service_worker);
  listeners.install();
  listeners.startup();
  await new Promise(setImmediate);
  assert.equal(requests.length, 0);
  const response = await new Promise((resolve) => listeners.message({
    type: "downbender-enqueue", url: "https://example.com/video",
  }, { tab: { id: 1 } }, resolve));
  assert.equal(requests[0].source, "safari");
  assert.equal(response.ok, true);
  assert.equal(response.confirmed, false);
});
