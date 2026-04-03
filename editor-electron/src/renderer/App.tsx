import React, { useEffect, useState, useCallback } from "react";
import type { GuavaEngineAPI } from "../preload/preload";
import { SceneHierarchy } from "./panels/SceneHierarchy";
import { Inspector } from "./panels/Inspector";
import { Console } from "./panels/Console";
import { Toolbar } from "./panels/Toolbar";
import type { EntityNode, LogEntry, GizmoMode } from "../shared/rpc-types";

declare global {
  interface Window {
    guavaEngine: GuavaEngineAPI;
  }
}

export function App() {
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hierarchy, setHierarchy] = useState<EntityNode[]>([]);
  const [selectedEntity, setSelectedEntity] = useState<number | null>(null);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [gizmoMode, setGizmoMode] = useState<GizmoMode>("translate");

  useEffect(() => {
    const cleanupConnected = window.guavaEngine.onConnected(() => {
      setConnected(true);
      refreshHierarchy();
    });

    const cleanupError = window.guavaEngine.onError((err) => {
      setError(err);
    });

    const cleanupEvents = window.guavaEngine.onEvent((event, data) => {
      switch (event) {
        case "on:scene.changed":
          refreshHierarchy();
          break;
        case "on:selection.changed": {
          const d = data as { entityIds: number[] };
          setSelectedEntity(d.entityIds[0] ?? null);
          break;
        }
        case "on:console.log":
          setLogs((prev) => [...prev.slice(-499), data as LogEntry]);
          break;
      }
    });

    // Check if already connected
    window.guavaEngine.getStatus().then((status) => {
      if (status.rpcConnected) {
        setConnected(true);
        refreshHierarchy();
      }
    });

    // Keyboard shortcuts
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      switch (e.key.toLowerCase()) {
        case "w": setGizmoMode("translate"); handleGizmoChange("translate"); break;
        case "e": setGizmoMode("rotate"); handleGizmoChange("rotate"); break;
        case "r": setGizmoMode("scale"); handleGizmoChange("scale"); break;
        case "delete":
        case "backspace":
          if (selectedEntity != null) {
            window.guavaEngine.call("scene.deleteEntity", { entityId: selectedEntity });
            setSelectedEntity(null);
            refreshHierarchy();
          }
          break;
      }
    };
    window.addEventListener("keydown", handleKeyDown);

    return () => {
      cleanupConnected();
      cleanupError();
      cleanupEvents();
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, []);

  const refreshHierarchy = useCallback(async () => {
    try {
      const result = await window.guavaEngine.call("scene.getHierarchy", {});
      setHierarchy(result.roots);
    } catch (e) {
      console.error("Failed to fetch hierarchy:", e);
    }
  }, []);

  const handleSelectEntity = useCallback(async (entityId: number) => {
    setSelectedEntity(entityId);
    try {
      await window.guavaEngine.call("editor.setSelection", {
        entityIds: [entityId],
      });
    } catch (e) {
      console.error("Failed to set selection:", e);
    }
  }, []);

  const handleGizmoChange = useCallback((mode: GizmoMode) => {
    setGizmoMode(mode);
    window.guavaEngine.call("viewport.setGizmoMode", { mode }).catch(() => {});
  }, []);

  const handleClearLogs = useCallback(() => {
    setLogs([]);
    window.guavaEngine.call("console.clear", {}).catch(() => {});
  }, []);

  if (error) {
    return (
      <div style={styles.errorContainer}>
        <h2>Engine Connection Error</h2>
        <p>{error}</p>
        <p style={{ opacity: 0.6, marginTop: 8 }}>
          Make sure guava-engine is running with --editor-server
        </p>
      </div>
    );
  }

  if (!connected) {
    return (
      <div style={styles.loadingContainer}>
        <div style={styles.spinner} />
        <p>Connecting to engine...</p>
      </div>
    );
  }

  return (
    <div style={styles.root}>
      <Toolbar gizmoMode={gizmoMode} onGizmoModeChange={handleGizmoChange} />
      <div style={styles.mainContent}>
        <div style={styles.leftPanel}>
          <SceneHierarchy
            roots={hierarchy}
            selectedId={selectedEntity}
            onSelect={handleSelectEntity}
            onRefresh={refreshHierarchy}
          />
        </div>
        <div style={styles.viewport}>
          <div style={styles.viewportPlaceholder}>
            <p>Viewport</p>
            <p style={{ fontSize: 12, opacity: 0.5 }}>
              Engine rendering window will be embedded here
            </p>
          </div>
        </div>
        <div style={styles.rightPanel}>
          <Inspector entityId={selectedEntity} />
        </div>
      </div>
      <div style={styles.bottomPanel}>
        <Console logs={logs} onClear={handleClearLogs} />
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  root: {
    display: "flex",
    flexDirection: "column",
    height: "100vh",
    background: "#1e1e2e",
  },
  mainContent: {
    display: "flex",
    flex: 1,
    overflow: "hidden",
  },
  leftPanel: {
    width: 260,
    minWidth: 200,
    borderRight: "1px solid #313244",
    overflow: "auto",
  },
  viewport: {
    flex: 1,
    background: "#11111b",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
  },
  viewportPlaceholder: {
    textAlign: "center" as const,
    opacity: 0.3,
  },
  rightPanel: {
    width: 320,
    minWidth: 250,
    borderLeft: "1px solid #313244",
    overflow: "auto",
  },
  bottomPanel: {
    height: 200,
    borderTop: "1px solid #313244",
    overflow: "auto",
  },
  loadingContainer: {
    display: "flex",
    flexDirection: "column" as const,
    alignItems: "center",
    justifyContent: "center",
    height: "100vh",
    gap: 16,
  },
  errorContainer: {
    display: "flex",
    flexDirection: "column" as const,
    alignItems: "center",
    justifyContent: "center",
    height: "100vh",
    gap: 8,
    color: "#f38ba8",
  },
  spinner: {
    width: 24,
    height: 24,
    border: "3px solid #45475a",
    borderTop: "3px solid #89b4fa",
    borderRadius: "50%",
    animation: "spin 1s linear infinite",
  },
};
