import React, { useEffect, useRef, useState } from "react";
import { useI18n } from "../i18n";

interface ViewportProps {
  connected: boolean;
}

/**
 * Viewport panel — transparent placeholder that tracks its screen position
 * and syncs the engine's SDL window to overlay exactly on top.
 */
export function Viewport({ connected }: ViewportProps) {
  const { t } = useI18n();
  const ref = useRef<HTMLDivElement>(null);
  const [synced, setSynced] = useState(false);

  useEffect(() => {
    if (!connected) {
      setSynced(false);
      return;
    }

    let raf: number;
    let last = { x: 0, y: 0, w: 0, h: 0 };

    const tick = () => {
      const el = ref.current;
      if (el) {
        const rect = el.getBoundingClientRect();
        const x = Math.round(window.screenX + rect.left);
        const y = Math.round(window.screenY + rect.top);
        const w = Math.round(rect.width);
        const h = Math.round(rect.height);

        if (w > 0 && h > 0 && (x !== last.x || y !== last.y || w !== last.w || h !== last.h)) {
          last = { x, y, w, h };
          window.guavaEngine
            .call("viewport.setRect", { x, y, width: w, height: h })
            .then(() => setSynced(true))
            .catch(() => setSynced(false));
        }
      }
      raf = requestAnimationFrame(tick);
    };

    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [connected]);

  return (
    <div ref={ref} style={styles.container}>
      {!synced && (
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
    flex: 1,
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
