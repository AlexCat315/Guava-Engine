import React from "react";

export function Toolbar() {
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
        <ToolButton icon="↕" tooltip="Translate (W)" />
        <ToolButton icon="⟳" tooltip="Rotate (E)" />
        <ToolButton icon="⤢" tooltip="Scale (R)" />
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
}: {
  icon: string;
  tooltip: string;
  onClick?: () => void;
}) {
  return (
    <button style={styles.button} title={tooltip} onClick={onClick}>
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
    transition: "background 0.1s",
  },
  brand: {
    fontSize: 11,
    color: "#585b70",
    fontWeight: 600,
    letterSpacing: 0.5,
    WebkitAppRegion: "drag",
  } as React.CSSProperties,
};
