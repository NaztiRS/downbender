(() => {
  "use strict";

  const layer = document.getElementById("site-fog");
  if (!layer) return;

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const compactViewport = window.matchMedia("(max-width: 560px)");
  const connection =
    navigator.connection ||
    navigator.mozConnection ||
    navigator.webkitConnection;

  const assets = [
    [
      "vendor/three-r134.min.js",
      "sha384-9EQoUIJYrv09/oYhSxnw1VpLcfPw3BM9dE7+D/3wGUPeLLa7F9Z6OAoD+i/M6FK9"
    ],
    [
      "vendor/vanta-fog-0.5.24.min.js",
      "sha384-6pWFXNNSqb0oVNIZRz63YH5+lolGdFdCh23nHfD7SI3PIW69QAVOvVl/0pkWLG62"
    ]
  ];

  const fogOptions = Object.freeze({
    highlightColor: 0xc0c0c0,
    midtoneColor: 0x747474,
    lowlightColor: 0x242424,
    baseColor: 0x050505,
    blurFactor: 0.65,
    speed: 1.5,
    zoom: 0.5,
    mouseControls: true
  });

  let pageReady = document.readyState === "complete";
  let effect = null;
  let effectCanvas = null;
  let librariesPromise = null;
  let fatal = false;
  let generation = 0;
  let webglAvailable;

  function applyFogStyles() {
    layer.style.opacity = "0.7";
    layer.style.filter = "brightness(20%)";
    if (effectCanvas) effectCanvas.style.filter = "blur(1px)";
  }

  function canUseWebGL() {
    if (webglAvailable !== undefined) return webglAvailable;

    try {
      const canvas = document.createElement("canvas");
      const options = { failIfMajorPerformanceCaveat: true };
      const context =
        canvas.getContext("webgl2", options) ||
        canvas.getContext("webgl", options);

      webglAvailable = Boolean(context);
      context
        ?.getExtension("WEBGL_lose_context")
        ?.loseContext();
    } catch {
      webglAvailable = false;
    }

    return webglAvailable;
  }

  function loadScript([path, integrity]) {
    return new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = new URL(path, document.baseURI).href;
      script.integrity = integrity;
      script.crossOrigin = "anonymous";
      script.onload = resolve;
      script.onerror = () => {
        script.remove();
        reject(new Error(`Failed to load ${path}`));
      };
      document.head.append(script);
    });
  }

  function loadLibraries() {
    librariesPromise ||= (async () => {
      if (!window.THREE?.WebGLRenderer) await loadScript(assets[0]);
      if (!window.VANTA?.FOG) await loadScript(assets[1]);

      if (!window.THREE?.WebGLRenderer || !window.VANTA?.FOG) {
        throw new Error("Vanta FOG is unavailable.");
      }
    })();

    return librariesPromise;
  }

  function contextLost(event) {
    event?.preventDefault();
    fatal = true;
    generation += 1;
    destroy();
  }

  function dispose(instance) {
    if (!instance) return;

    const renderer = instance.renderer;
    const canvas = renderer?.domElement;
    canvas?.removeEventListener("webglcontextlost", contextLost);

    try { instance.destroy?.(); } catch {}
    try { renderer?.renderLists?.dispose?.(); } catch {}
    try { renderer?.dispose?.(); } catch {}
    try { renderer?.forceContextLoss?.(); } catch {}
    canvas?.remove();
  }

  function destroy() {
    const oldEffect = effect;
    effect = null;
    effectCanvas = null;
    dispose(oldEffect);
    layer.dataset.fog = "static";
  }

  function shouldRun() {
    return (
      pageReady &&
      document.visibilityState === "visible" &&
      !reduceMotion.matches &&
      !connection?.saveData &&
      !fatal
    );
  }

  function capRender(instance, fps = 30) {
    const renderer = instance.renderer;
    const render = renderer.render.bind(renderer);
    let lastRender = -Infinity;

    renderer.render = (scene, camera) => {
      const now = performance.now();
      if (now - lastRender < 1000 / fps) return;
      lastRender = now;
      render(scene, camera);
    };

    instance.isOnScreen = () => true;
  }

  async function reconcile() {
    const currentGeneration = ++generation;

    if (!shouldRun()) {
      destroy();
      return;
    }

    if (effect) return;

    if (!canUseWebGL()) {
      fatal = true;
      return;
    }

    try {
      await loadLibraries();
    } catch {
      fatal = true;
      return;
    }

    if (
      currentGeneration !== generation ||
      !shouldRun() ||
      effect
    ) {
      return;
    }

    let candidate;

    try {
      candidate = window.VANTA.FOG({
        el: layer,
        THREE: window.THREE,
        touchControls: true,
        gyroControls: false,
        minWidth: 200,
        minHeight: 200,
        ...fogOptions,
        scale: Math.max(2, window.devicePixelRatio || 1),
        scaleMobile: 2
      });
    } catch {
      fatal = true;
      dispose(candidate);
      return;
    }

    const canvas = candidate?.renderer?.domElement;
    if (!canvas?.isConnected || !candidate.scene || !candidate.camera) {
      fatal = true;
      dispose(candidate);
      return;
    }

    effect = candidate;
    effectCanvas = canvas;
    capRender(effect, compactViewport.matches ? 24 : 30);
    canvas.setAttribute("aria-hidden", "true");
    canvas.addEventListener("webglcontextlost", contextLost, { once: true });
    applyFogStyles();
    layer.dataset.fog = "animated";
  }

  const changed = () => void reconcile();
  reduceMotion.addEventListener?.("change", changed);
  connection?.addEventListener?.("change", changed);
  document.addEventListener("visibilitychange", changed);

  window.addEventListener("pagehide", () => {
    generation += 1;
    destroy();
  });
  window.addEventListener("pageshow", changed);

  applyFogStyles();

  if (pageReady) {
    void reconcile();
  } else {
    window.addEventListener(
      "load",
      () => {
        pageReady = true;
        void reconcile();
      },
      { once: true }
    );
  }
})();
