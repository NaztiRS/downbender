importScripts("url-utils.js");

const extensionAPI = globalThis.browser || chrome;
const platform = globalThis.DownbenderPlatform || {};
const NATIVE_HOST = "com.naztirs.downbender";
const CONTEXT_MENU_ID = "download-with-downbender";
const {
  canonicalDownloadURL,
  isWebURL,
  looksLikeDirectMedia,
  singleVideoDownloadURL,
} = globalThis.DownbenderURLs;

async function showBadge(tabId, text, color) {
  if (typeof tabId !== "number") return;
  // Safari does not implement every badge API. Feedback must never block delivery.
  try {
    await extensionAPI.action.setBadgeBackgroundColor?.({ tabId, color });
    await extensionAPI.action.setBadgeText({ tabId, text });
    setTimeout(() => extensionAPI.action.setBadgeText({ tabId, text: "" }).catch(() => {}), 1800);
  } catch { /* The overlay still provides feedback when the toolbar badge is unavailable. */ }
}

async function sendToDownbender(message, tabId) {
  if (!isWebURL(message?.url)) {
    const result = { ok: false, message: "This is not a downloadable web address." };
    await showBadge(tabId, "!", "#F1BA62");
    return result;
  }

  try {
    const target = message.source === "active-video-overlay"
      ? singleVideoDownloadURL(message.url)
      : canonicalDownloadURL(message.url);
    if (!target) {
      const result = { ok: false, message: "Could not identify a single video." };
      await showBadge(tabId, "!", "#F1BA62");
      return result;
    }
    const response = await extensionAPI.runtime.sendNativeMessage(NATIVE_HOST, {
      command: "enqueue",
      url: target,
      source: message.source || platform.source || "chrome",
      title: message.title || null,
      pageURL: message.pageURL || null,
      mediaURL: message.mediaURL || null,
    });
    if (!response?.ok) throw new Error(response?.message || "Downbender did not accept the link.");
    await showBadge(tabId, "✓", "#67D391");
    return { ok: true, confirmed: response.confirmed !== false };
  } catch (error) {
    await showBadge(tabId, "!", "#FF6B6B");
    return {
      ok: false,
      message: error instanceof Error ? error.message : "Could not reach Downbender.",
    };
  }
}

async function rebuildContextMenu() {
  await extensionAPI.contextMenus.removeAll();
  extensionAPI.contextMenus.create({
    id: CONTEXT_MENU_ID,
    title: "Download with Downbender",
    contexts: ["page", "link", "video", "audio"],
    documentUrlPatterns: ["http://*/*", "https://*/*"],
  });
}

async function confirmExtensionInstalled() {
  if (platform.confirmInstallation === false) return;
  try {
    await extensionAPI.runtime.sendNativeMessage(NATIVE_HOST, {
      command: "extension-installed",
    });
  } catch {
    // Keep the temporary shortcut when the host is unavailable. Downbender offers a verified
    // manual cleanup fallback, and a later Chrome startup will retry automatically.
  }
}

extensionAPI.runtime.onInstalled.addListener(() => {
  rebuildContextMenu().catch(() => {});
  confirmExtensionInstalled();
});

extensionAPI.runtime.onStartup.addListener(() => {
  rebuildContextMenu().catch(() => {});
  confirmExtensionInstalled();
});

extensionAPI.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== CONTEXT_MENU_ID) return;
  let target = info.pageUrl || tab?.url;
  if (info.linkUrl && isWebURL(info.linkUrl)) target = info.linkUrl;
  if (looksLikeDirectMedia(info.srcUrl)) target = info.srcUrl;
  sendToDownbender(
    {
      url: target,
      source: `context-${info.mediaType || (info.linkUrl ? "link" : "page")}`,
      title: tab?.title,
      pageURL: info.pageUrl || tab?.url,
      mediaURL: isWebURL(info.srcUrl) ? info.srcUrl : null,
    },
    tab?.id,
  );
});

extensionAPI.action.onClicked.addListener((tab) => {
  sendToDownbender(
    {
      url: tab.url,
      source: "toolbar",
      title: tab.title,
      pageURL: tab.url,
    },
    tab.id,
  );
});

extensionAPI.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type !== "downbender-enqueue") return false;
  sendToDownbender(message, sender.tab?.id).then(sendResponse);
  return true;
});
