(() => {
  const {
    canonicalDownloadURL,
    isYouTubeURL,
    singleVideoDownloadURL,
  } = globalThis.DownbenderURLs;
  const MIN_WIDTH = 180;
  const MIN_HEIGHT = 100;
  const ACTIVE_GRACE_MS = 1400;
  const YOUTUBE_CARD_SELECTOR = [
    "ytd-rich-item-renderer",
    "ytd-video-renderer",
    "ytd-grid-video-renderer",
    "ytd-rich-grid-media",
    "ytd-compact-video-renderer",
    "ytd-reel-item-renderer",
    "ytd-playlist-video-renderer",
    "yt-lockup-view-model",
    ".yt-lockup-view-model",
  ].join(",");
  const YOUTUBE_LINK_SELECTOR = [
    "a[href*='/watch?']",
    "a[href*='/shorts/']",
    "a[href*='/live/']",
    "a[href*='youtu.be/']",
  ].join(",");
  const videos = new Set();
  const playback = new WeakMap();
  const dismissedVideos = new WeakSet();
  const dismissedTargets = new Set();

  let activeVideo = null;
  let overlayHost = null;
  let overlayButton = null;
  let overlayText = null;
  let overlayHovered = false;
  let pointerX = -1;
  let pointerY = -1;
  let lastEvaluation = 0;
  let feedbackTimer = null;
  let lastPointedYouTubeVideo = null;

  function registerVideo(video) {
    if (!(video instanceof HTMLVideoElement) || videos.has(video)) return;
    videos.add(video);
    playback.set(video, {
      lastTime: Number.isFinite(video.currentTime) ? video.currentTime : 0,
      lastAdvancedAt: 0,
      lastPlayedAt: 0,
      lastInteractionAt: 0,
    });
  }

  function registerVideosBelow(node) {
    if (!(node instanceof Element)) return;
    if (node instanceof HTMLVideoElement) registerVideo(node);
    node.querySelectorAll?.("video").forEach(registerVideo);
  }

  function stateFor(video) {
    registerVideo(video);
    return playback.get(video);
  }

  function noteVideoEvent(event) {
    if (!(event.target instanceof HTMLVideoElement)) return;
    const state = stateFor(event.target);
    const now = performance.now();
    if (event.type === "play" || event.type === "playing") state.lastPlayedAt = now;
    if (event.isTrusted) state.lastInteractionAt = now;
    evaluate(true);
  }

  function ensureOverlay() {
    if (overlayHost?.isConnected) {
      mountOverlayForFullscreen();
      return;
    }

    overlayHost = document.createElement("div");
    overlayHost.id = "downbender-active-video-control";
    Object.assign(overlayHost.style, {
      position: "fixed",
      inset: "0 auto auto 0",
      zIndex: "2147483647",
      display: "none",
      pointerEvents: "none",
      transform: "translate3d(0, 0, 0)",
    });

    const shadow = overlayHost.attachShadow({ mode: "closed" });
    const style = document.createElement("style");
    style.textContent = `
      .control {
        display: inline-flex;
        position: relative;
        pointer-events: auto;
      }
      .download {
        appearance: none;
        box-sizing: border-box;
        display: inline-flex;
        align-items: center;
        gap: 5px;
        height: 30px;
        margin: 0;
        padding: 3px 10px 3px 3px;
        overflow: hidden;
        isolation: isolate;
        position: relative;
        border: 1px solid rgba(137, 218, 255, .58);
        border-radius: 999px;
        background: rgba(5, 18, 34, .94);
        -webkit-backdrop-filter: blur(10px);
        backdrop-filter: blur(10px);
        box-shadow:
          0 5px 16px rgba(0, 0, 0, .42),
          inset 0 1px rgba(255, 255, 255, .1);
        color: white;
        cursor: pointer;
        font: 600 12px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        letter-spacing: .1px;
        pointer-events: auto;
        white-space: nowrap;
        transition: transform 120ms ease, box-shadow 120ms ease, filter 120ms ease;
      }
      .download:hover {
        border-color: rgba(166, 230, 255, .9);
        background: rgba(8, 29, 52, .97);
        box-shadow:
          0 6px 19px rgba(0, 0, 0, .48),
          0 0 0 1px rgba(45, 176, 237, .16);
        transform: translateY(-1px);
      }
      .download:active { transform: translateY(0) scale(.98); }
      .mark {
        display: grid;
        flex: 0 0 auto;
        width: 22px;
        height: 22px;
        place-items: center;
        border-radius: 50%;
        filter: drop-shadow(0 1px 3px rgba(75, 194, 255, .3));
      }
      .mark img {
        display: block;
        width: 22px;
        height: 22px;
        object-fit: contain;
      }
      .download[data-state="sending"] .mark img { animation: pulse 650ms ease-in-out infinite alternate; }
      .download[data-state="sent"] { border-color: rgba(74, 222, 128, .9); }
      .download[data-state="error"] { border-color: rgba(248, 113, 113, .95); }
      .dismiss {
        appearance: none;
        box-sizing: border-box;
        display: grid;
        position: absolute;
        top: -6px;
        right: -6px;
        width: 17px;
        height: 17px;
        margin: 0;
        padding: 0 0 1px;
        place-items: center;
        border: 1px solid rgba(137, 218, 255, .62);
        border-radius: 50%;
        background: rgba(5, 18, 34, .98);
        box-shadow: 0 2px 7px rgba(0, 0, 0, .48);
        color: rgba(255, 255, 255, .9);
        cursor: pointer;
        font: 700 12px/1 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        pointer-events: auto;
        transition: background 120ms ease, border-color 120ms ease, transform 120ms ease;
      }
      .dismiss:hover {
        border-color: rgba(255, 255, 255, .9);
        background: rgba(24, 53, 79, .99);
        transform: scale(1.08);
      }
      .dismiss:active { transform: scale(.94); }
      @keyframes pulse { to { transform: translateY(2px); filter: brightness(1.2); } }
      @media (prefers-reduced-motion: reduce) {
        .download, .dismiss { transition: none; }
        .download[data-state="sending"] .mark img { animation: none; }
      }
    `;

    const control = document.createElement("div");
    control.className = "control";
    overlayButton = document.createElement("button");
    overlayButton.className = "download";
    overlayButton.type = "button";
    overlayButton.title = "Download this video with Downbender";
    overlayButton.setAttribute("aria-label", "Download this video with Downbender");
    const mark = document.createElement("span");
    mark.className = "mark";
    const appIcon = document.createElement("img");
    appIcon.src = chrome.runtime.getURL("icons/icon-128.png");
    appIcon.alt = "";
    mark.append(appIcon);
    overlayText = document.createElement("span");
    overlayText.textContent = "Download";
    overlayButton.append(mark, overlayText);
    const dismissButton = document.createElement("button");
    dismissButton.className = "dismiss";
    dismissButton.type = "button";
    dismissButton.textContent = "×";
    dismissButton.title = "Hide for this video until the page reloads";
    dismissButton.setAttribute("aria-label", "Hide for this video until the page reloads");
    control.append(overlayButton, dismissButton);
    shadow.append(style, control);
    document.documentElement.append(overlayHost);

    control.addEventListener("pointerenter", () => { overlayHovered = true; });
    control.addEventListener("pointerleave", () => { overlayHovered = false; });
    overlayButton.addEventListener("click", sendActiveVideo);
    dismissButton.addEventListener("click", dismissActiveVideo);
  }

  function mountOverlayForFullscreen() {
    if (!overlayHost) return;
    const fullscreen = document.fullscreenElement;
    // YouTube and most custom players fullscreen a container, where an extension control can
    // remain visible. A raw <video> is a replaced element and cannot render injected children.
    const parent = fullscreen && !(fullscreen instanceof HTMLVideoElement)
      ? fullscreen
      : document.documentElement;
    if (overlayHost.parentElement !== parent) parent.append(overlayHost);
  }

  function isPointerInside(rect) {
    return pointerX >= rect.left && pointerX <= rect.right &&
      pointerY >= rect.top && pointerY <= rect.bottom;
  }

  function visibleArea(rect) {
    const width = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
    const height = Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
    return width * height;
  }

  function isEligible(video, rect) {
    if (!video.isConnected || rect.width < MIN_WIDTH || rect.height < MIN_HEIGHT) return false;
    // Live WebRTC feeds are calls, camera previews, or screen shares—not downloadable videos.
    if (typeof MediaStream !== "undefined" && video.srcObject instanceof MediaStream) return false;
    if (visibleArea(rect) < MIN_WIDTH * MIN_HEIGHT * 0.35) return false;
    const style = getComputedStyle(video);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) < 0.05) return false;
    if (location.hostname.endsWith("youtube.com") && video.closest(".html5-video-player.ad-showing")) return false;
    return true;
  }

  function scoreVideo(video, rect, state, now) {
    const time = Number.isFinite(video.currentTime) ? video.currentTime : 0;
    if (Math.abs(time - state.lastTime) >= 0.025) state.lastAdvancedAt = now;
    state.lastTime = time;

    const playing = !video.paused && !video.ended && video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA;
    const hoveredPreview = isPointerInside(rect) && now - state.lastAdvancedAt < ACTIVE_GRACE_MS;
    if (!playing && !hoveredPreview && !(overlayHovered && video === activeVideo)) return null;
    if (isDismissed(video)) return null;

    let score = playing ? 10_000 : 4_000;
    if (isPointerInside(rect)) score += 3_000;
    if (!video.muted && video.volume > 0) score += 500;
    score += Math.min(2_000, visibleArea(rect) / 500);
    score += Math.max(0, 500 - (now - state.lastPlayedAt) / 10);
    score += Math.max(0, 300 - (now - state.lastInteractionAt) / 10);
    return score;
  }

  function positionOverlay(video) {
    ensureOverlay();
    const rect = video.getBoundingClientRect();
    const width = overlayButton.offsetWidth || 104;
    const height = overlayButton.offsetHeight || 30;
    const left = Math.max(8, Math.min(innerWidth - width - 8, rect.right - width - 10));
    const top = Math.max(8, Math.min(innerHeight - height - 8, rect.top + 10));
    overlayHost.style.transform = `translate3d(${Math.round(left)}px, ${Math.round(top)}px, 0)`;
  }

  function setActiveVideo(video) {
    if (!video) {
      if (!overlayHovered && overlayHost) overlayHost.style.display = "none";
      activeVideo = overlayHovered ? activeVideo : null;
      return;
    }
    activeVideo = video;
    ensureOverlay();
    overlayHost.style.display = "block";
    positionOverlay(video);
  }

  function evaluate(force = false) {
    const now = performance.now();
    if (!force && now - lastEvaluation < 180) return;
    lastEvaluation = now;

    let winner = null;
    let winningScore = -Infinity;
    for (const video of videos) {
      if (!video.isConnected) {
        videos.delete(video);
        continue;
      }
      const rect = video.getBoundingClientRect();
      if (!isEligible(video, rect)) continue;
      const score = scoreVideo(video, rect, stateFor(video), now);
      if (score !== null && score > winningScore) {
        winner = video;
        winningScore = score;
      }
    }
    setActiveVideo(winner);
  }

  function youtubeURLFromCard(card) {
    const links = card?.querySelectorAll?.(YOUTUBE_LINK_SELECTOR) || [];
    for (const link of links) {
      const target = singleVideoDownloadURL(link.href);
      if (target) return target;
    }
    return null;
  }

  function youtubeURLFromElement(element) {
    if (!(element instanceof Element)) return null;

    const directLink = element.closest("a[href]");
    const directTarget = directLink ? singleVideoDownloadURL(directLink.href) : null;
    if (directTarget) return directTarget;

    const card = element.closest(YOUTUBE_CARD_SELECTOR);
    return youtubeURLFromCard(card);
  }

  function overlapArea(first, second) {
    const width = Math.max(0, Math.min(first.right, second.right) - Math.max(first.left, second.left));
    const height = Math.max(0, Math.min(first.bottom, second.bottom) - Math.max(first.top, second.top));
    return width * height;
  }

  function youtubeURLAtPoint(x, y) {
    if (x < 0 || y < 0 || x > innerWidth || y > innerHeight) return null;
    for (const element of document.elementsFromPoint(x, y)) {
      const target = youtubeURLFromElement(element);
      if (target) return target;
    }
    return null;
  }

  function youtubeURLOverlappingVideo(video) {
    const videoRect = video.getBoundingClientRect();
    const minimumOverlap = Math.max(400, videoRect.width * videoRect.height * 0.08);
    let bestTarget = null;
    let bestOverlap = 0;

    // YouTube sometimes portals the preview player outside its card in the DOM. Match the
    // preview back to the underlying card by screen position instead of DOM ancestry.
    for (const card of document.querySelectorAll(YOUTUBE_CARD_SELECTOR)) {
      const overlap = overlapArea(videoRect, card.getBoundingClientRect());
      if (overlap <= bestOverlap || overlap < minimumOverlap) continue;
      const target = youtubeURLFromCard(card);
      if (!target) continue;
      bestTarget = target;
      bestOverlap = overlap;
    }
    if (bestTarget) return bestTarget;

    // New YouTube layouts may omit a stable card element, but their thumbnail link still
    // occupies the same rectangle as the preview.
    for (const link of document.querySelectorAll(YOUTUBE_LINK_SELECTOR)) {
      const overlap = overlapArea(videoRect, link.getBoundingClientRect());
      if (overlap <= bestOverlap || overlap < minimumOverlap) continue;
      const target = singleVideoDownloadURL(link.href);
      if (!target) continue;
      bestTarget = target;
      bestOverlap = overlap;
    }
    return bestTarget;
  }

  function youtubeCardURL(video) {
    if (!/(^|\.)youtube\.com$/i.test(location.hostname)) return null;
    if (/^\/(watch|shorts\/|live\/)/.test(location.pathname)) {
      return singleVideoDownloadURL(location.href);
    }

    const nestedTarget = youtubeURLFromElement(video);
    if (nestedTarget) return nestedTarget;

    const videoRect = video.getBoundingClientRect();
    if (lastPointedYouTubeVideo &&
        performance.now() - lastPointedYouTubeVideo.at < 10_000 &&
        lastPointedYouTubeVideo.x >= videoRect.left && lastPointedYouTubeVideo.x <= videoRect.right &&
        lastPointedYouTubeVideo.y >= videoRect.top && lastPointedYouTubeVideo.y <= videoRect.bottom) {
      return lastPointedYouTubeVideo.url;
    }

    const centerTarget = youtubeURLAtPoint(
      videoRect.left + videoRect.width / 2,
      videoRect.top + videoRect.height / 2,
    );
    return centerTarget || youtubeURLOverlappingVideo(video);
  }

  function targetFor(video) {
    const youtube = youtubeCardURL(video);
    if (youtube) return youtube;
    // On a YouTube listing page, falling back to the page URL can enqueue a Mix or playlist.
    // The overlay must fail closed unless its exact video ID was found in the surrounding card.
    if (isYouTubeURL(location.href)) return null;

    const enclosingLink = video.closest("a[href]");
    if (enclosingLink?.href && /^https?:/i.test(enclosingLink.href)) {
      return canonicalDownloadURL(enclosingLink.href);
    }

    const canonical = document.querySelector("link[rel='canonical'][href]")?.href;
    if (canonical && /^https?:/i.test(canonical)) return canonicalDownloadURL(canonical);
    return canonicalDownloadURL(location.href);
  }

  function dismissalKeyFor(video) {
    const youtube = youtubeCardURL(video);
    if (youtube) return `youtube:${youtube}`;

    const enclosingLink = video.closest("a[href]");
    if (enclosingLink?.href && /^https?:/i.test(enclosingLink.href)) {
      return `link:${canonicalDownloadURL(enclosingLink.href)}`;
    }

    const mediaURL = video.currentSrc || video.src;
    if (/^https?:/i.test(mediaURL)) return `media:${mediaURL}`;
    return null;
  }

  function isDismissed(video) {
    if (dismissedVideos.has(video)) return true;
    if (dismissedTargets.size === 0) return false;
    const key = dismissalKeyFor(video);
    return Boolean(key && dismissedTargets.has(key));
  }

  function dismissActiveVideo(event) {
    event.preventDefault();
    event.stopPropagation();
    const video = activeVideo;
    if (!video) return;

    const key = dismissalKeyFor(video);
    if (key) dismissedTargets.add(key);
    else dismissedVideos.add(video);

    clearTimeout(feedbackTimer);
    feedbackTimer = null;
    overlayButton.dataset.state = "";
    overlayText.textContent = "Download";
    overlayButton.title = "Download this video with Downbender";
    overlayHovered = false;
    activeVideo = null;
    overlayHost.style.display = "none";
    evaluate(true);
  }

  function setFeedback(state, text, title) {
    ensureOverlay();
    clearTimeout(feedbackTimer);
    overlayButton.dataset.state = state;
    overlayText.textContent = text;
    overlayButton.title = title;
    feedbackTimer = setTimeout(() => {
      overlayButton.dataset.state = "";
      overlayText.textContent = "Download";
      overlayButton.title = "Download this video with Downbender";
    }, state === "error" ? 2600 : 1400);
  }

  async function sendActiveVideo(event) {
    event.preventDefault();
    event.stopPropagation();
    const video = activeVideo;
    if (!video) return;
    const target = targetFor(video);
    if (!target) {
      setFeedback("error", "Video not found", "Could not identify this single video");
      return;
    }
    setFeedback("sending", "Sending…", "Sending this video to Downbender");
    try {
      const response = await chrome.runtime.sendMessage({
        type: "downbender-enqueue",
        url: target,
        source: "active-video-overlay",
        title: document.title,
        pageURL: location.href,
        mediaURL: /^https?:/i.test(video.currentSrc || "") ? video.currentSrc : null,
      });
      if (!response?.ok) throw new Error(response?.message || "Could not reach Downbender.");
      setFeedback("sent", "Added", "Video added to Downbender");
    } catch (error) {
      const message = error instanceof Error ? error.message : "Could not reach Downbender.";
      setFeedback("error", "Offline", message);
    }
  }

  document.querySelectorAll("video").forEach(registerVideo);
  new MutationObserver((records) => {
    for (const record of records) {
      record.addedNodes.forEach(registerVideosBelow);
    }
  }).observe(document.documentElement, { childList: true, subtree: true });

  for (const name of ["play", "playing", "pause", "ended", "loadeddata", "timeupdate"]) {
    document.addEventListener(name, noteVideoEvent, true);
  }
  document.addEventListener("pointermove", (event) => {
    pointerX = event.clientX;
    pointerY = event.clientY;
    if (isYouTubeURL(location.href)) {
      const pointedURL = youtubeURLAtPoint(pointerX, pointerY);
      if (pointedURL) {
        lastPointedYouTubeVideo = {
          url: pointedURL,
          x: pointerX,
          y: pointerY,
          at: performance.now(),
        };
      }
    }
    evaluate();
  }, { capture: true, passive: true });
  document.addEventListener("pointerdown", (event) => {
    if (event.target instanceof HTMLVideoElement) stateFor(event.target).lastInteractionAt = performance.now();
  }, true);
  addEventListener("scroll", () => evaluate(true), { capture: true, passive: true });
  addEventListener("resize", () => evaluate(true), { passive: true });
  document.addEventListener("fullscreenchange", () => evaluate(true));
  setInterval(() => evaluate(true), 350);
})();
