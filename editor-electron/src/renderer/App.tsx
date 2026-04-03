import React, { useEffect, useState, useCallback } from "react";
import type { GuavaEngineAPI } from "../preload/preload";
import { SceneHierarchy } from "./panels/SceneHierarchy";
import { Inspector } from "./panels/Inspector";
import { Console } from "./panels/Console";
import { Toolbar } from "./panels/Toolbar";
import { Viewport } from "./panels/Viewport";
import { RenderSettingsPanel } from "./panels/RenderSettings";
import { MaterialEditor } from "./panels/MaterialEditor";
import { AssetBrowser } from "./panels/AssetBrowser";
import { ViewportStatus } from "./panels/ViewportStatus";
import { CommandTimeline } from "./panels/CommandTimeline";
import { EditorUtilities } from "./panels/EditorUtilities";
import { CameraBookmarks } from "./panels/CameraBookmarks";
import { RhiStats } from "./panels/RhiStats";
import { AudioMixer } from "./panels/AudioMixer";
import { PluginManager } from "./panels/PluginManager";
import { StyleInspector } from "./panels/StyleInspector";
import { PlaceActors } from "./panels/PlaceActors";
import { RenderQueue } from "./panels/RenderQueue";
import { PhysicsVisualization } from "./panels/PhysicsVisualization";
import { PostProcessEditor } from "./panels/PostProcessEditor";
import { useI18n } from "./i18n";
import type { EntityNode, LogEntry, GizmoMode } from "../shared/rpc-types";

declare global {
  interface Window {
    guavaEngine: GuavaEngineAPI;
  }
}

export function App() {
  const { t } = useI18n();
  const [connected, setConnected] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [hierarchy, setHierarchy] = useState<EntityNode[]>([]);
  const [selectedEntity, setSelectedEntity] = useState<number | null>(null);
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [gizmoMode, setGizmoMode] = useState<GizmoMode>("translate");
  const [bottomTab, setBottomTab] = useState<"console" | "assets" | "timeline" | "utilities" | "camera" | "rhistats" | "audio" | "plugins" | "style" | "placeactors" | "renderqueue" | "physicsviz" | "postprocess">("console");

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
      // Ctrl/Cmd+S → Save scene
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        window.guavaEngine.call("scene.save", {}).catch(() => {});
        return;
      }
      // Ctrl/Cmd+Z → Undo, Ctrl/Cmd+Shift+Z → Redo
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
        e.preventDefault();
        if (e.shiftKey) {
          window.guavaEngine.call("editor.redo", {}).catch(() => {});
        } else {
          window.guavaEngine.call("editor.undo", {}).catch(() => {});
        }
        return;
      }
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
        <h2>{t.app.connectionError}</h2>
        <p>{error}</p>
        <p style={{ opacity: 0.6, marginTop: 8 }}>
          {t.app.engineNotRunning}
        </p>
      </div>
    );
  }

  if (!connected) {
    return (
      <div style={styles.loadingContainer}>
        <div style={styles.spinner} />
        <p>{t.app.connectingToEngine}</p>
      </div>
    );
  }

  return (
    <div style={styles.root}>
      <Toolbar gizmoMode={gizmoMode} onGizmoModeChange={handleGizmoChange} onRefreshHierarchy={refreshHierarchy} />
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
          <Viewport connected={connected} />
        </div>
        <div style={styles.rightPanel}>
          <Inspector entityId={selectedEntity} />
          <MaterialEditor entityId={selectedEntity} />
          <RenderSettingsPanel connected={connected} />
        </div>
      </div>
      <div style={styles.bottomPanel}>
        <div style={styles.bottomTabs}>
          <button
            style={{ ...styles.tab, ...(bottomTab === "console" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("console")}
          >
            {t.app.tabConsole}
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "assets" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("assets")}
          >
            {t.app.tabAssets}
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "timeline" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("timeline")}
          >
            {t.app.tabTimeline}
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "utilities" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("utilities")}
          >
            {t.app.tabUtilities}
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "camera" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("camera")}
          >
            Camera
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "rhistats" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("rhistats")}
          >
            RHI Stats
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "audio" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("audio")}
          >
            Audio
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "plugins" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("plugins")}
          >
            Plugins
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "style" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("style")}
          >
            Style
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "placeactors" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("placeactors")}
          >
            Place
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "renderqueue" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("renderqueue")}
          >
            Render Q
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "physicsviz" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("physicsviz")}
          >
            Physics
          </button>
          <button
            style={{ ...styles.tab, ...(bottomTab === "postprocess" ? styles.tabActive : {}) }}
            onClick={() => setBottomTab("postprocess")}
          >
            Post-FX
          </button>
        </div>
        <div style={styles.bottomContent}>
          {bottomTab === "console" ? (
            <Console logs={logs} onClear={handleClearLogs} />
          ) : bottomTab === "assets" ? (
            <AssetBrowser connected={connected} />
          ) : bottomTab === "utilities" ? (
            <EditorUtilities connected={connected} />
          ) : bottomTab === "camera" ? (
            <CameraBookmarks connected={connected} />
          ) : bottomTab === "rhistats" ? (
            <RhiStats connected={connected} />
          ) : bottomTab === "audio" ? (
            <AudioMixer connected={connected} />
          ) : bottomTab === "plugins" ? (
            <PluginManager connected={connected} />
          ) : bottomTab === "style" ? (
            <StyleInspector connected={connected} />
          ) : bottomTab === "placeactors" ? (
            <PlaceActors connected={connected} />
          ) : bottomTab === "renderqueue" ? (
            <RenderQueue connected={connected} />
          ) : bottomTab === "physicsviz" ? (
            <PhysicsVisualization connected={connected} />
          ) : bottomTab === "postprocess" ? (
            <PostProcessEditor connected={connected} />
          ) : (
            <CommandTimeline connected={connected} />
          )}
        </div>
      </div>
      <ViewportStatus connected={connected} />
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
    background: "transparent",
    position: "relative",
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
    display: "flex",
    flexDirection: "column" as const,
  },
  bottomTabs: {
    display: "flex",
    background: "#181825",
    borderBottom: "1px solid #313244",
    gap: 0,
  },
  tab: {
    padding: "6px 16px",
    background: "transparent",
    border: "none",
    borderBottom: "2px solid transparent",
    color: "#6c7086",
    fontSize: 12,
    cursor: "pointer",
    fontWeight: 500,
  },
  tabActive: {
    color: "#cdd6f4",
    borderBottomColor: "#89b4fa",
  },
  bottomContent: {
    flex: 1,
    overflow: "hidden",
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
