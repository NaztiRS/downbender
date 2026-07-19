(() => {
  function parsedWebURL(value) {
    try {
      const url = new URL(value);
      return url.protocol === "https:" || url.protocol === "http:" ? url : null;
    } catch {
      return null;
    }
  }

  function isWebURL(value) {
    return parsedWebURL(value) !== null;
  }

  function isYouTubeURL(value) {
    const url = parsedWebURL(value);
    if (!url) return false;
    const hostname = url.hostname.toLowerCase();
    return hostname === "youtu.be" || hostname === "youtube.com" || hostname.endsWith(".youtube.com");
  }

  function canonicalDownloadURL(value) {
    const url = parsedWebURL(value);
    if (!url) return value;

    const hostname = url.hostname.toLowerCase();
    if (hostname === "youtu.be") {
      const videoID = url.pathname.split("/").filter(Boolean)[0];
      return videoID ? `https://www.youtube.com/watch?v=${encodeURIComponent(videoID)}` : value;
    }
    if (hostname !== "youtube.com" && !hostname.endsWith(".youtube.com")) return value;

    if (url.pathname === "/watch") {
      const videoID = url.searchParams.get("v");
      // A playing video is always a single-video action. Deliberately discard list/index,
      // including YouTube's enormous auto-generated Mix playlists.
      return videoID ? `https://www.youtube.com/watch?v=${encodeURIComponent(videoID)}` : value;
    }

    const standalonePath = url.pathname.match(/^\/(shorts|live)\/([^/?#]+)/);
    if (standalonePath) {
      return `https://www.youtube.com/${standalonePath[1]}/${encodeURIComponent(standalonePath[2])}`;
    }
    // An explicit /playlist link remains a playlist action.
    return value;
  }

  // The control drawn over an active video is never a playlist action. On YouTube it must
  // resolve to an actual video ID; returning null is deliberately safer than enqueueing the
  // surrounding Home, Subscriptions, Mix, or playlist page.
  function singleVideoDownloadURL(value) {
    const url = parsedWebURL(value);
    if (!url) return null;
    if (!isYouTubeURL(value)) return canonicalDownloadURL(value);

    const hostname = url.hostname.toLowerCase();
    if (hostname === "youtu.be") {
      const videoID = url.pathname.split("/").filter(Boolean)[0];
      return videoID ? `https://www.youtube.com/watch?v=${encodeURIComponent(videoID)}` : null;
    }
    if (url.pathname === "/watch") {
      const videoID = url.searchParams.get("v");
      return videoID ? `https://www.youtube.com/watch?v=${encodeURIComponent(videoID)}` : null;
    }
    const standalonePath = url.pathname.match(/^\/(shorts|live)\/([^/?#]+)/);
    return standalonePath
      ? `https://www.youtube.com/${standalonePath[1]}/${encodeURIComponent(standalonePath[2])}`
      : null;
  }

  function looksLikeDirectMedia(value) {
    const url = parsedWebURL(value);
    return url !== null &&
      /\.(?:m4v|mkv|mov|mp3|mp4|mpeg|mpg|oga|ogg|ogv|opus|wav|webm)$/i.test(url.pathname);
  }

  globalThis.DownbenderURLs = Object.freeze({
    canonicalDownloadURL,
    isWebURL,
    isYouTubeURL,
    looksLikeDirectMedia,
    singleVideoDownloadURL,
  });
})();
