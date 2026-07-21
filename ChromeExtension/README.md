# Downbender Companion

This extension is distributed unpacked inside Downbender. The app creates a temporary
`Downbender Extension Installer` shortcut in Downloads and registers the native-messaging helper
when the user starts installation.

Click **Install Chrome Extension** in Downbender. After the app takes you to Chrome:

1. Enable **Developer mode**.
2. Click **Load unpacked**.
3. Choose **Downloads** in the sidebar and select `Downbender Extension Installer`.
4. Chrome confirms the installation to Downbender's native host, which removes the temporary
   shortcut automatically. Downbender also removes it when the app quits or after one hour.

The floating control is deliberately singular: it appears only over the video that is playing
or whose hover preview is advancing. Toolbar and context-menu actions remain available as
fallbacks. Its close button hides the control for that video until the page reloads.

The floating control is disabled on live meeting surfaces such as Google Meet, Microsoft Teams,
Zoom Web App, Webex web meetings, Jitsi Meet, and Whereby. Live WebRTC video streams are also
ignored so calls, camera previews, and screen shares do not trigger the control.
