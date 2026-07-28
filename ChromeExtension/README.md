# Downbender Companion

This extension is distributed unpacked inside Downbender. The app creates a temporary
`Downbender Extension Installer` shortcut in Downloads and registers the native-messaging helper
for the selected Chromium browser when the user starts installation.

In **Settings → Browser extension**, choose Google Chrome, Brave, Microsoft Edge, or Chromium
from the **Browser** menu, then click **Install extension**. After Downbender opens that browser's
extensions page:

1. Enable **Developer mode**.
2. Click **Load unpacked**.
3. Choose **Downloads** in the sidebar and select `Downbender Extension Installer`.
4. The browser confirms the installation to Downbender's native host, which removes the temporary
   shortcut automatically. Downbender also removes it when the app quits or after one hour.

The floating control is deliberately singular: it appears only over the video that is playing
or whose hover preview is advancing. Toolbar and context-menu actions remain available as
fallbacks. Its close button hides the control for that video until the page reloads.

The floating control is disabled on live meeting surfaces such as Google Meet, Microsoft Teams,
Zoom Web App, Webex web meetings, Jitsi Meet, and Whereby. Live WebRTC video streams are also
ignored so calls, camera previews, and screen shares do not trigger the control.
