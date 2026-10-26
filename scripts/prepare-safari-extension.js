const fs = require("node:fs");
const path = require("node:path");

// Packages the shared ChromeExtension scripts for Safari. Only the native delivery differs, so
// the background worker is a tiny wrapper that marks the platform and imports the shared one.
function prepareSafariResources(destination) {
  const root = path.join(__dirname, "..");
  const shared = path.join(root, "ChromeExtension");
  const manifest = JSON.parse(fs.readFileSync(path.join(shared, "manifest.json"), "utf8"));
  delete manifest.key;
  delete manifest.incognito;
  manifest.name = "Downbender";
  manifest.browser_specific_settings = { safari: { strict_min_version: "26.0" } };
  fs.mkdirSync(destination, { recursive: true });
  fs.writeFileSync(path.join(destination, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  for (const name of ["content.js", "url-utils.js"]) {
    fs.copyFileSync(path.join(shared, name), path.join(destination, name));
  }
  fs.cpSync(path.join(shared, "icons"), path.join(destination, "icons"), { recursive: true });
  fs.copyFileSync(path.join(shared, "background.js"), path.join(destination, "background-shared.js"));
  fs.copyFileSync(path.join(root, "SafariExtension/background.js"), path.join(destination, "background.js"));
}

module.exports = { prepareSafariResources };
if (require.main === module) {
  if (!process.argv[2]) throw new Error("Usage: node scripts/prepare-safari-extension.js OUTPUT_DIRECTORY");
  prepareSafariResources(process.argv[2]);
}
