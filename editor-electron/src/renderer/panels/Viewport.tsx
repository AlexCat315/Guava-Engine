import React, { useEffect, useRef, useState, useCallback } from "react";
import { useI18n } from "../i18n";
import { ViewCube } from "./ViewCube";

type ShadingMode = "solid" | "material" | "rendered" | "wireframe";

const SHADING_ICONS: Record<ShadingMode, string> = {
  solid: "◻",
  material: "◼",
  rendered: "◉",
  wireframe: "▦",
};

interface ViewportProps {
  connected: boolean;
}

/**
 * Viewport panel — cross-platform engine viewport display.
 *
 * macOS: Uses IOSurface texture sharing (native CALayer behind Electron window).
 * Linux: Uses POSIX shared memory + canvas pixel rendering.
 *
 * Flow:
 *  1. On connect, tell the engine the desired viewport size (viewport.setRect).
 *  2. Poll viewport.getSurfaceId to get the surfaceId (and optional shmName).
 *  3. Pass the surface id + element bounds to the main process via IPC.
 *  4. macOS: main process creates a CALayer backed by IOSurface.
 *     Linux: main process opens shm, pushes pixel data via "viewport:pixels" IPC.
 *  5. On resize / position change, update the layer frame via IPC.
 */
export function Viewport({ connected }: ViewportProps) {
  const { t } = useI18n();
  const ref = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [attached, setAttached] = useState(false);
  const surfaceIdRef = useRef(0);
  const shmNameRef = useRef<string | undefined>(undefined);
  const lastBoundsRef = useRef({ x: 0, y: 0, w: 0, h: 0 });
  const [shadingMode, setShadingMode] = useState<ShadingMode>("material");

  // Fetch current shading mode on connect
  useEffect(() => {
    if (!connected) return;
    window.guavaEngine.call("viewport.getRenderSettings", {})
      .then((res) => { if (res.shadingMode) setShadingMode(res.shadingMode as ShadingMode); })
      .catch(() => {});
  }, [connected]);

  const handleShadingChange = useCallback((mode: ShadingMode) => {
    setShadingMode(mode);
    window.guavaEngine.call("viewport.setRenderSettings", { shadingMode: mode } as never).catch(() => {});
  }, []);

  // ── Input forwarding to the engine ─────────────────────────────
  const dpr = window.devicePixelRatio || 1;

  const toViewportCoords = useCallback((e: React.MouseEvent) => {
    const el = ref.current;
    if (!el) return { x: 0, y: 0 };
    const rect = el.getBoundingClientRect();
    return { x: (e.clientX - rect.left) * dpr, y: (e.clientY - rect.top) * dpr };
  }, [dpr]);

  const sendInput = useCallback((params: Record<string, unknown>) => {
    window.guavaEngine.call("viewport.sendInput", params as never).catch(() => {});
  }, []);

  // Track mousedown position for click-to-pick detection
  const mouseDownPos = useRef<{ x: number; y: number } | null>(null);

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    const { x, y } = toViewportCoords(e);
    const btn = e.button === 0 ? "left" : e.button === 2 ? "right" : e.button === 1 ? "middle" : null;
    if (!btn) return;
    if (btn === "left") mouseDownPos.current = { x, y };
    sendInput({ type: "mousedown", x, y, button: btn, clicks: e.detail, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [toViewportCoords, sendInput]);

  const handleMouseUp = useCallback((e: React.MouseEvent) => {
    const { x, y } = toViewportCoords(e);
    const btn = e.button === 0 ? "left" : e.button === 2 ? "right" : e.button === 1 ? "middle" : null;
    if (!btn) return;
    sendInput({ type: "mouseup", x, y, button: btn, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });

    // Click-to-pick: if LMB released close to where it was pressed, trigger entity pick
    if (btn === "left" && mouseDownPos.current && !e.altKey) {
      const dx = x - mouseDownPos.current.x;
      const dy = y - mouseDownPos.current.y;
      if (dx * dx + dy * dy < 16) { // < 4px movement
        const mode = (e.shiftKey || e.ctrlKey || e.metaKey) ? "toggle" : "replace";
        window.guavaEngine.call("viewport.pick", { x: Math.round(x), y: Math.round(y), mode } as never).catch(() => {});
      }
      mouseDownPos.current = null;
    }
  }, [toViewportCoords, sendInput]);

  const handleMouseMove = useCallback((e: React.MouseEvent) => {
    const { x, y } = toViewportCoords(e);
    sendInput({ type: "mousemove", x, y, deltaX: e.movementX * dpr, deltaY: e.movementY * dpr, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [toViewportCoords, sendInput, dpr]);

  const handleWheel = useCallback((e: React.WheelEvent) => {
    sendInput({ type: "wheel", deltaX: -e.deltaX / 120, deltaY: -e.deltaY / 120, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [sendInput]);

  const handleContextMenu = useCallback((e: React.MouseEvent) => { e.preventDefault(); }, []);

  const mapKeyFn = (e: React.KeyboardEvent): string | null => {
    const k = e.key.toLowerCase();
    const m: Record<string, string> = { arrowup: "up", arrowdown: "down", arrowleft: "left", arrowright: "right", " ": "space", ".": "period" };
    if (m[k]) return m[k];
    if (/^[a-z0-9]$/.test(k)) return k;
    if (/^f([1-9]|1[0-2])$/.test(k)) return k;
    if (["tab", "delete", "backspace", "shift", "control", "alt", "escape"].includes(k)) return k === "control" ? "ctrl" : k;
    return null;
  };

  const handleKeyDown = useCallback((e: React.KeyboardEvent) => {
    const key = mapKeyFn(e);
    if (!key) return;
    sendInput({ type: "keydown", key, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [sendInput]);

  const handleKeyUp = useCallback((e: React.KeyboardEvent) => {
    const key = mapKeyFn(e);
    if (!key) return;
    sendInput({ type: "keyup", key, shift: e.shiftKey, ctrl: e.ctrlKey || e.metaKey, alt: e.altKey });
  }, [sendInput]);

  // Compute element bounds relative to the window's content origin (points).
  const getBounds = useCallback(() => {
    const el = ref.current;
    if (!el) return null;
    const rect = el.getBoundingClientRect();
    const x = Math.round(rect.left);
    const y = Math.round(rect.top);
    const w = Math.round(rect.width);
    const h = Math.round(rect.height);
    if (w <= 0 || h <= 0) return null;
    return { x, y, w, h };
  }, []);

  // Initialisation: request engine viewport size + attach IOSurface layer.
  // Initialisation: request engine viewport size + attach IOSurface layer.
  useEffect(() => {
    if (!connected) {
      if (surfaceIdRef.current) {
        window.guavaEngine.viewportDetach().catch(() => {});
        setAttached(false);
      }
      surfaceIdRef.current = 0;
      return;
    }

    // Don't re-init if already attached.
    if (attached) return;

    let cancelled = false;

    const init = async () => {
      // Wait for the element to be laid out (the div may not have dimensions
      // yet on the same tick as the React render that adds it to the DOM).
      let bounds = getBounds();
      for (let wait = 0; !bounds && wait < 20 && !cancelled; wait++) {
        await new Promise((r) => requestAnimationFrame(r));
        bounds = getBounds();
      }
      if (!bounds || cancelled) return;

      // Tell the engine the desired viewport dimensions.
      try {
        await window.guavaEngine.call("viewport.setRect", {
          x: bounds.x,
          y: bounds.y,
          width: bounds.w,
          height: bounds.h,
        });
      } catch {
        // Engine may not be fully ready yet — retry is handled below.
      }

      // Wait a short moment for the engine to create the IOSurface after
      // the first setRect (the first frame must be rendered).
      await new Promise((r) => setTimeout(r, 500));
      if (cancelled) return;

      // Poll until a valid surfaceId is available.
      for (let attempt = 0; attempt < 20 && !cancelled; attempt++) {
        try {
          const res = await window.guavaEngine.call("viewport.getSurfaceId", {});
          if (res.surfaceId && res.surfaceId > 0) {
            surfaceIdRef.current = res.surfaceId;
            shmNameRef.current = res.shmName ?? undefined;
            const ok = await window.guavaEngine.viewportAttachSurface(
              res.surfaceId,
              bounds.x,
              bounds.y,
              bounds.w,
              bounds.h,
              res.shmName ?? undefined,
            );
            if (ok) {
              lastBoundsRef.current = bounds;
              setAttached(true);
              return;
            }
          }
        } catch {
          // Engine not ready yet — keep polling.
        }
        await new Promise((r) => setTimeout(r, 250));
      }
    };

    init();

    return () => {
      cancelled = true;
    };
  }, [connected, attached, getBounds]); // attached in deps so disconnect→reconnect re-inits

  // Track position / size changes and update the CALayer frame.
  useEffect(() => {
    if (!attached) return;

    let raf: number;

    const tick = () => {
      const bounds = getBounds();
      if (bounds) {
        const last = lastBoundsRef.current;
        if (
          bounds.x !== last.x ||
          bounds.y !== last.y ||
          bounds.w !== last.w ||
          bounds.h !== last.h
        ) {
          lastBoundsRef.current = bounds;
          window.guavaEngine.viewportUpdateFrame(bounds.x, bounds.y, bounds.w, bounds.h);

          // If the size changed, also tell the engine to resize.
          if (bounds.w !== last.w || bounds.h !== last.h) {
            window.guavaEngine
              .call("viewport.setRect", {
                x: bounds.x,
                y: bounds.y,
                width: bounds.w,
                height: bounds.h,
              })
              .then(async () => {
                // Give the engine a moment to recreate the IOSurface, then
                // poll for the new surface id.
                await new Promise((r) => setTimeout(r, 100));
                try {
                  const res = await window.guavaEngine.call("viewport.getSurfaceId", {});
                  if (res.surfaceId && res.surfaceId !== surfaceIdRef.current) {
                    surfaceIdRef.current = res.surfaceId;
                    shmNameRef.current = res.shmName ?? undefined;
                    window.guavaEngine.viewportUpdateSurface(
                      res.surfaceId,
                      res.shmName ?? undefined,
                      res.width,
                      res.height,
                    );
                  }
                } catch {
                  // Best-effort.
                }
              })
              .catch(() => {});
          }
        }
      }
      raf = requestAnimationFrame(tick);
    };

    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [attached, getBounds]);

  // Cleanup on unmount.
  useEffect(() => {
    return () => {
      window.guavaEngine.viewportDetach().catch(() => {});
    };
  }, []);

  // Linux pixel rendering: subscribe to viewport:pixels from main process.
  useEffect(() => {
    if (!attached) return;
    const unsub = window.guavaEngine.onViewportPixels((pixels, width, height) => {
      const canvas = canvasRef.current;
      if (!canvas) return;
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
      }
      const ctx = canvas.getContext("2d");
      if (!ctx) return;
      // pixels is BGRA from Vulkan readback — convert to RGBA for ImageData.
      const src = new Uint8Array(pixels.buffer, pixels.byteOffset, pixels.byteLength);
      const rgba = new Uint8ClampedArray(src.length);
      for (let i = 0; i < src.length; i += 4) {
        rgba[i] = src[i + 2];     // R ← B
        rgba[i + 1] = src[i + 1]; // G
        rgba[i + 2] = src[i];     // B ← R
        rgba[i + 3] = src[i + 3]; // A
      }
      const img = new ImageData(rgba, width, height);
      ctx.putImageData(img, 0, 0);
    });
    return unsub;
  }, [attached]);

  return (
    <div style={styles.outerContainer}>
      {/* Toolbar row — outside the IOSurface area so it's not occluded */}
      {connected && (
        <div style={styles.toolbarRow}>
          <div style={styles.shadingBar}>
            {(["solid", "material", "rendered", "wireframe"] as ShadingMode[]).map((mode) => (
              <button
                key={mode}
                title={mode.charAt(0).toUpperCase() + mode.slice(1)}
                style={{
                  ...styles.shadingButton,
                  ...(shadingMode === mode ? styles.shadingButtonActive : {}),
                }}
                onClick={() => handleShadingChange(mode)}
              >
                {SHADING_ICONS[mode]}
              </button>
            ))}
          </div>
          <div style={{ flex: 1 }} />
          <ViewCube connected={connected} />
        </div>
      )}
      {/* Viewport rendering area — IOSurface/canvas is positioned here */}
      <div
        ref={ref}
        style={styles.container}
        tabIndex={0}
        onMouseDown={handleMouseDown}
        onMouseUp={handleMouseUp}
        onMouseMove={handleMouseMove}
        onWheel={handleWheel}
        onContextMenu={handleContextMenu}
        onKeyDown={handleKeyDown}
        onKeyUp={handleKeyUp}
      >
        <canvas ref={canvasRef} style={styles.canvas} />
        {!attached && (
          <div style={styles.placeholder}>
            <p style={{ margin: 0, fontSize: 14 }}>{t.viewport.title}</p>
            <p style={{ margin: "4px 0 0", fontSize: 12, opacity: 0.5 }}>
              {connected ? t.viewport.syncingEngine : t.viewport.waitingForEngine}
            </p>
          </div>
        )}
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  outerContainer: {
    width: "100%",
    height: "100%",
    display: "flex",
    flexDirection: "column",
    background: "transparent",
    overflow: "hidden",
  },
  toolbarRow: {
    display: "flex",
    alignItems: "flex-start",
    padding: "3px 6px",
    background: "#181825",
    borderBottom: "1px solid #313244",
    gap: 6,
  },
  container: {
    flex: 1,
    background: "transparent",
    position: "relative",
    overflow: "hidden",
  },
  canvas: {
    position: "absolute",
    inset: 0,
    width: "100%",
    height: "100%",
    imageRendering: "pixelated",
  },
  shadingBar: {
    display: "flex",
    gap: 2,
    alignSelf: "center",
  },
  shadingButton: {
    background: "transparent",
    border: "1px solid transparent",
    borderRadius: 4,
    color: "#a6adc8",
    cursor: "pointer",
    padding: "4px 8px",
    fontSize: 13,
    lineHeight: "1",
    minWidth: 28,
    textAlign: "center" as const,
    transition: "all 0.1s",
  },
  shadingButtonActive: {
    background: "#45475a",
    borderColor: "#89b4fa",
    color: "#89b4fa",
  },
  placeholder: {
    position: "absolute",
    inset: 0,
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    color: "#cdd6f4",
    opacity: 0.3,
    pointerEvents: "none",
  },
};
