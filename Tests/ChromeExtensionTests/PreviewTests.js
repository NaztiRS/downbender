const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const { JSDOM } = require("jsdom");

const extension = path.join(__dirname, "../../ChromeExtension");

function previewPage(t, url = "https://www.youtube.com/feed/subscriptions", extraHTML = "") {
  const dom = new JSDOM(`<!doctype html>${extraHTML}<ytd-video-preview>
    <div class="ytdVideoPreviewMediaContainer">
      <a class="ytdVideoPreviewMediaContainerLink" href="/watch?v=preview123&list=RDpreview123">
        <div class="html5-video-player"><video></video></div>
      </a>
    </div>
  </ytd-video-preview>`, { url, runScripts: "outside-only", pretendToBeVisual: true });
  t.after(() => dom.window.close());
  const { window } = dom;
  const { document } = window;
  const messages = [];
  const shadows = new WeakMap();
  const attachShadow = window.Element.prototype.attachShadow;
  window.Element.prototype.attachShadow = function (options) {
    const shadow = attachShadow.call(this, options);
    shadows.set(this, shadow);
    return shadow;
  };
  window.chrome = { runtime: {
    getURL: (asset) => `chrome-extension://test/${asset}`,
    sendMessage: async (message) => { messages.push(message); return { ok: true }; },
  } };
  // jsdom has no layout or media engine; the DOM, events and content script are real.
  document.elementsFromPoint = () => [];
  const video = document.querySelector("video");
  const link = document.querySelector("a");
  const media = { paused: false, ended: false, readyState: 4, currentTime: 1,
    currentSrc: "blob:https://www.youtube.com/preview-one" };
  for (const key of Object.keys(media)) {
    Object.defineProperty(video, key, { get: () => media[key] });
  }
  let visible = true;
  video.style.opacity = "1";
  video.getBoundingClientRect = () => visible
    ? { left: 100, top: 100, right: 540, bottom: 348, width: 440, height: 248 }
    : { left: 0, top: 0, right: 0, bottom: 0, width: 0, height: 0 };
  for (const file of ["url-utils.js", "content.js"]) {
    window.eval(fs.readFileSync(path.join(extension, file), "utf8"));
  }
  const host = document.getElementById("downbender-active-video-control");
  const shadow = shadows.get(host);
  const control = shadow.querySelector(".control");
  const button = shadow.querySelector(".download");
  return {
    window, document, video, link, media, messages, host, button,
    dismiss: shadow.querySelector(".dismiss"),
    enterControl() { control.dispatchEvent(new window.Event("pointerenter")); },
    hidePreview() {
      link.removeAttribute("href");
      visible = false;
      media.paused = true;
      video.dispatchEvent(new window.Event("pause"));
    },
    async download() { button.click(); await new Promise(setImmediate); },
  };
}

test("subscriptions preview still sends its video after hovering the button tears down the preview", async (t) => {
  const page = previewPage(t);
  assert.equal(page.host.style.display, "block");
  page.enterControl();
  page.hidePreview();
  await page.download();
  assert.equal(page.messages.length, 1, "the preview's target must survive until the button click");
  assert.equal(page.messages[0].url, "https://www.youtube.com/watch?v=preview123");
  assert.equal(page.messages[0].source, "active-video-overlay");
});

test("normal watch playback continues to send the page video", async (t) => {
  const page = previewPage(t, "https://www.youtube.com/watch?v=watch123&list=RDwatch123");
  await page.download();
  assert.equal(page.messages[0]?.url, "https://www.youtube.com/watch?v=watch123");
  assert.equal(page.button.title, "Video added to Downbender");
});

test("Safari delivery does not claim that the app confirmed enqueue", async (t) => {
  const page = previewPage(t);
  page.window.chrome.runtime.sendMessage = async () => ({ ok: true, confirmed: false });
  await page.download();
  assert.equal(page.button.title, "Link sent to Downbender");
  assert.match(page.button.textContent, /Sent/);
});

test("reinjecting the detector in the same document keeps one usable overlay", async (t) => {
  const page = previewPage(t);
  page.window.eval(fs.readFileSync(path.join(extension, "content.js"), "utf8"));
  assert.equal(page.document.querySelectorAll("#downbender-active-video-control").length, 1);
  await page.download();
  assert.equal(page.messages.length, 1);
  assert.equal(page.messages[0].url, "https://www.youtube.com/watch?v=preview123");
});

test("a page element named browser cannot replace the Chromium extension API", async (t) => {
  const page = previewPage(t, undefined, '<div id="browser"></div>');
  await page.download();
  assert.equal(page.messages.length, 1);
  assert.equal(page.button.title, "Video added to Downbender");
});

test("a reused preview player sends the new video, not the previous target", async (t) => {
  const page = previewPage(t);
  page.media.currentSrc = "blob:https://www.youtube.com/preview-two";
  page.link.href = "/watch?v=second123&list=RDsecond123";
  page.video.dispatchEvent(new page.window.Event("playing"));
  page.enterControl();
  page.hidePreview();
  await page.download();
  assert.equal(page.messages[0]?.url, "https://www.youtube.com/watch?v=second123");
});

test("a different unidentified preview cannot reuse the last video's target", async (t) => {
  const page = previewPage(t);
  page.media.currentSrc = "blob:https://www.youtube.com/unknown-preview";
  page.link.removeAttribute("href");
  page.video.dispatchEvent(new page.window.Event("playing"));
  await page.download();
  assert.equal(page.messages.length, 0);
  assert.equal(page.button.dataset.state, "error");
});

test("SPA navigation cannot reuse a target from the previous listing", async (t) => {
  const page = previewPage(t);
  page.enterControl();
  page.hidePreview();
  page.window.history.pushState({}, "", "/");
  await page.download();
  assert.equal(page.messages.length, 0);
  assert.equal(page.button.dataset.state, "error");
});

test("a new load clears the remembered target even if the player reuses its source", async (t) => {
  const page = previewPage(t);
  page.enterControl();
  page.hidePreview();
  page.video.dispatchEvent(new page.window.Event("loadstart"));
  await page.download();
  assert.equal(page.messages.length, 0);
  assert.equal(page.button.dataset.state, "error");
});

test("starting a load before preview teardown cannot recapture the old link", async (t) => {
  const page = previewPage(t);
  page.video.dispatchEvent(new page.window.Event("loadstart"));
  page.enterControl();
  page.hidePreview();
  await page.download();
  assert.equal(page.messages.length, 0);
  assert.equal(page.button.dataset.state, "error");
});

test("the new preview becomes downloadable after its media loads", async (t) => {
  const page = previewPage(t);
  page.video.dispatchEvent(new page.window.Event("loadstart"));
  page.link.href = "/watch?v=second123";
  page.media.currentSrc = "blob:https://www.youtube.com/preview-two";
  page.video.dispatchEvent(new page.window.Event("loadeddata"));
  page.enterControl();
  page.hidePreview();
  await page.download();
  assert.equal(page.messages[0]?.url, "https://www.youtube.com/watch?v=second123");
});

test("dismissing a torn-down preview does not dismiss every video in the shared player", async (t) => {
  const page = previewPage(t);
  page.enterControl();
  page.hidePreview();
  page.dismiss.click();
  page.media.currentSrc = "blob:https://www.youtube.com/preview-two";
  page.media.paused = false;
  page.link.href = "/watch?v=second123";
  page.video.getBoundingClientRect = () =>
    ({ left: 100, top: 100, right: 540, bottom: 348, width: 440, height: 248 });
  page.video.dispatchEvent(new page.window.Event("playing"));
  assert.equal(page.host.style.display, "block");
  await page.download();
  assert.equal(page.messages[0]?.url, "https://www.youtube.com/watch?v=second123");
});
