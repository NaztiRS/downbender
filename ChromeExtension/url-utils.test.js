const assert = require("node:assert/strict");

require("./url-utils.js");

const { canonicalDownloadURL, singleVideoDownloadURL } = globalThis.DownbenderURLs;

assert.equal(
  canonicalDownloadURL("https://www.youtube.com/watch?v=video123&list=RDvideo123&index=4&start_radio=1"),
  "https://www.youtube.com/watch?v=video123",
);
assert.equal(
  canonicalDownloadURL("https://m.youtube.com/watch?list=PLhuge&v=subscriptionVideo"),
  "https://www.youtube.com/watch?v=subscriptionVideo",
);
assert.equal(
  canonicalDownloadURL("https://youtu.be/shortID?si=tracking"),
  "https://www.youtube.com/watch?v=shortID",
);
assert.equal(
  canonicalDownloadURL("https://www.youtube.com/shorts/shortID?feature=share"),
  "https://www.youtube.com/shorts/shortID",
);
assert.equal(
  canonicalDownloadURL("https://www.youtube.com/playlist?list=PLintentional"),
  "https://www.youtube.com/playlist?list=PLintentional",
);
assert.equal(canonicalDownloadURL("https://vimeo.com/123"), "https://vimeo.com/123");
assert.equal(
  singleVideoDownloadURL("https://www.youtube.com/watch?v=video123&list=RDvideo123&index=4"),
  "https://www.youtube.com/watch?v=video123",
);
assert.equal(singleVideoDownloadURL("https://www.youtube.com/playlist?list=PLhuge"), null);
assert.equal(singleVideoDownloadURL("https://www.youtube.com/feed/subscriptions"), null);
assert.equal(singleVideoDownloadURL("https://vimeo.com/123"), "https://vimeo.com/123");

console.log("extension URL tests passed");
