import React, { useEffect, useRef, useState, useCallback } from "react";
import { useI18n } from "../i18n";

interface ViewportProps {
  connected: boolean;
}

/**
 * Viewport panel — uses IOSurface texture sharing to display the engine's
 * rendered frame directly as a CALayer inside the Electron window (macOS).
 *
 * Flow:
 *  1. On connect, tell the engine the desired viewport size (viewport.setRect).
 *  2. Poll viewport.getSurfaceId to get the IOSurface id.
 *  3. Pass the surface id + element bounds to the main process via IPC.
 *  4. Main process creates a CALayer backed by the IOSurface.
 *  5. On resize /  position change, update the layer frame via IPC.
 */
export function Viewport({ connected }: ViewportProps) {
  const { t } = useI18n();
  const ref = useRef<HTMLDivElement>(null);
  const [attached, setAttached] = useState(false);
  const surfaceIdRef = useRef(0);
  const lastBoundsRef = useRef({ x: 0, y: 0, w: 0, h: 0 });

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
            const ok = await window.guavaEngine.viewportAttachSurface(
              res.surfaceId,
              bounds.x,
              bounds.y,
              bounds.w,
              bounds.h,
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
                    window.guavaEngine.viewportUpdateSurface(res.surfaceId);
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

  return (
    <div ref={ref} style={styles.container}>
      {!attached && (
        <div style={styles.placeholder}>
          <p style={{ margin: 0, fontSize: 14 }}>{t.viewport.title}</p>
          <p style={{ margin: "4px 0 0", fontSize: 12, opacity: 0.5 }}>
            {connected ? t.viewport.syncingEngine : t.viewport.waitingForEngine}
          </p>
        </div>
      )}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: {
    width: "100%",
    height: "100%",
    background: "transparent",
    position: "relative",
    overflow: "hidden",
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
