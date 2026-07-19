# Downbender Companion

This extension is distributed unpacked inside Downbender. The app creates a temporary
`Downbender Extension Installer` shortcut in Downloads and registers the native-messaging helper
when the user starts installation.

Install it in Chrome:

1. Open `chrome://extensions`.
2. Enable **Developer mode**.
3. Click **Load unpacked**.
4. Choose **Downloads** in the sidebar and select `Downbender Extension Installer`.
5. Chrome confirms the installation to Downbender's native host, which verifies and removes the
   temporary shortcut automatically. **Clean up manually** remains available as a fallback.

Chrome resolves the shortcut and runs the real extension inside `Downbender.app`, so no permanent
installation folder remains in Downloads.

The floating control is deliberately singular: it appears only over the video that is playing
or whose hover preview is advancing. Toolbar and context-menu actions remain available as
fallbacks.
