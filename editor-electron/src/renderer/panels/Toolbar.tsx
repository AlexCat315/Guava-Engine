import React from "react";
import type { GizmoMode } from "../../shared/rpc-types";

interface ToolbarProps {
  gizmoMode: GizmoMode;
  onGizmoModeChange: (mode: GizmoMode) => void;
}

export function Toolbar({ gizmoMode, onGizmoModeChange }: ToolbarProps) {
  const handlePlay = () => window.guavaEngine.call("playback.play", {});
  const handlePause = () => window.guavaEngine.call("playback.pause", {});
  const handleStop = () => window.guavaEngine.call("playback.stop", {});
  const handleUndo = () => window.guavaEngine.call("editor.undo", {});
  const handleRedo = () => window.guavaEngine.call("editor.redo", {});

  return (
    <div style={styles.toolbar}>
      <div style={styles.section}>
        <ToolButton icon="↩" tooltip="Undo" onClick={handleUndo} />
        <ToolButton icon="↪" tooltip="Redo" onClick={handleRedo} />
      </div>
      <div style={styles.divider} />
      <div style={styles.section}>
        <ToolButton icon="▶" tooltip="Play" onClick={handlePlay} />
        <ToolButton icon="⏸" tooltip="Pause" onClick={handlePause} />
        <ToolButton icon="⏹" tooltip="Stop" onClick={handleStop} />
      </div>
      <div style={styles.divider} />
      <div style={styles.section}>
        <ToolButton
          icon="↕"
          tooltip="Translate (W)"
          active={gizmoMode === "translate"}
          onClick={() => onGizmoModeChange("translate")}
        />
        <ToolButton
          icon="⟳"
          tooltip="Rotate (E)"
          active={gizmoMode === "rotate"}
          onClick={() => onGizmoModeChange("rotate")}
        />
        <ToolButton
          icon="⤢"
          tooltip="Scale (R)"
          active={gizmoMode === "scale"}
          onClick={() => onGizmoModeChange("scale")}
        />
      </div>
      <div style={{ flex: 1 }} />
      <div style={styles.section}>
        <span style={styles.brand}>Guava Editor</span>
      </div>
    </div>
  );
}

function ToolButton({
  icon,
  tooltip,
  onClick,
  active,
}: {
  icon: string;
  tooltip: string;
  onClick?: () => void;
  active?: boolean;
}) {
  return (
    <button
      style={{
        ...styles.button,
        ...(active && {
          background: "#45475a",
          borderColor: "#89b4fa",
          color: "#89b4fa",
        }),
      }}
      title={tooltip}
      onClick={onClick}
    >
      {icon}
    </button>
  );
}

const styles = {
  toolbar: {
    display: "flex",
    alignItems: "center",
    padding: "4px 12px",
    background: "#181825",
    borderBottom: "1px solid #313244",
    gap: 4,
    minHeight: 36,
    WebkitAppRegion: "drag",
  } as React.CSSProperties,
  section: {
    display: "flex",
    alignItems: "center",
    gap: 2,
    WebkitAppRegion: "no-drag",
  } as React.CSSProperties,
  divider: {
    width: 1,
    height: 20,
    background: "#313244",
    margin: "0 6px",
  },
  button: {
    background: "transparent",
    border: "1px solid transparent",
    borderRadius: 4,
    color: "#a6adc8",
    cursor: "pointer",
    padding: "4px 8px",
    fontSize: 14,
    lineHeight: 1,
    transition: "all 0.1s",
  },
  brand: {
    fontSize: 11,
    color: "#585b70",
    fontWeight: 600,
    letterSpacing: 0.5,
    WebkitAppRegion: "drag",
  } as React.CSSProperties,
};
