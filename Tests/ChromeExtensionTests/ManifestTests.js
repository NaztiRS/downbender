const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const manifestPath = path.join(__dirname, "../../ChromeExtension/manifest.json");
const contentPath = path.join(__dirname, "../../ChromeExtension/content.js");
const manifest = require(manifestPath);
const contentSource = fs.readFileSync(contentPath, "utf8");
const videoDetector = manifest.content_scripts?.find((entry) =>
  entry.js?.includes("content.js"),
);

assert.ok(videoDetector, "content.js must remain registered as a content script");
assert.equal(
  videoDetector.all_frames,
  true,
  "the video detector must run inside matching iframe documents",
);
assert.deepEqual(
  videoDetector.matches,
  ["http://*/*", "https://*/*"],
  "iframe detection must cover both supported web schemes",
);
assert.doesNotMatch(
  contentSource,
  /\bsetInterval\s*\(/,
  "content detection must remain event-driven instead of polling every frame forever",
);
assert.match(
  contentSource,
  /requestYouTubePointerLookup\(\)/,
  "YouTube pointer DOM lookup must remain behind its throttled scheduler",
);
assert.match(
  contentSource,
  /visibilitychange/,
  "content detection must stop scheduled work while its document is hidden",
);
assert.match(
  contentSource,
  /graceExpiryTimer\s*=\s*setTimeout/,
  "paused hover previews must schedule one trailing evaluation when their grace expires",
);
assert.match(
  contentSource,
  /record\.removedNodes\.forEach/,
  "removed videos must be released without waiting for another page event",
);
assert.match(
  contentSource,
  /new ResizeObserver\(\(\) => requestEvaluation\(\)\)/,
  "active video resizing must reposition the overlay without polling",
);
assert.match(
  contentSource,
  /yt-navigate-finish/,
  "YouTube SPA navigation must trigger a fresh event-driven evaluation",
);
assert.match(
  contentSource,
  /attributeFilter:\s*\["class", "style", "hidden"\]/,
  "relevant active-video layout changes must trigger a fresh evaluation",
);

const digest = crypto
  .createHash("sha256")
  .update(Buffer.from(manifest.key, "base64"))
  .digest()
  .subarray(0, 16);
const extensionID = [...digest.toString("hex")]
  .map((digit) => String.fromCharCode(97 + Number.parseInt(digit, 16)))
  .join("");
assert.equal(
  extensionID,
  "bfcndjoodnplbimoicmombomihhbjedm",
  "the fixed key must keep the native host's allowed extension ID stable",
);

console.log("extension manifest tests passed");
