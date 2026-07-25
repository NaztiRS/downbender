const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const path = require("node:path");

const manifestPath = path.join(__dirname, "../../ChromeExtension/manifest.json");
const manifest = require(manifestPath);
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
