import React, { useRef, useEffect } from "react";
import type { LogEntry } from "../../shared/rpc-types";

interface ConsoleProps {
  logs: LogEntry[];
}

const levelColors: Record<string, string> = {
  debug: "#6c7086",
  info: "#cdd6f4",
  warn: "#f9e2af",
  error: "#f38ba8",
};

export function Console({ logs }: ConsoleProps) {
  const endRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logs.length]);

  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <span style={styles.title}>Console</span>
        <span style={styles.count}>{logs.length}</span>
      </div>
      <div style={styles.logList}>
        {logs.length === 0 ? (
          <div style={styles.empty}>No logs</div>
        ) : (
          logs.map((log, i) => (
            <div key={i} style={styles.logEntry}>
              <span style={{ ...styles.level, color: levelColors[log.level] ?? "#cdd6f4" }}>
                [{log.level.toUpperCase()}]
              </span>
              <span style={styles.message}>{log.message}</span>
            </div>
          ))
        )}
        <div ref={endRef} />
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column", height: "100%" },
  header: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "6px 12px",
    borderBottom: "1px solid #313244",
    fontSize: 12,
    fontWeight: 600,
    textTransform: "uppercase" as const,
    letterSpacing: 0.5,
    color: "#a6adc8",
  },
  title: {},
  count: {
    background: "#45475a",
    borderRadius: 8,
    padding: "0 6px",
    fontSize: 10,
    color: "#a6adc8",
  },
  logList: { flex: 1, overflow: "auto", padding: 4, fontFamily: "monospace", fontSize: 12 },
  empty: { padding: 16, textAlign: "center" as const, opacity: 0.4 },
  logEntry: {
    display: "flex",
    gap: 8,
    padding: "1px 8px",
    borderBottom: "1px solid #181825",
  },
  level: { minWidth: 55, fontWeight: 600, fontSize: 11 },
  message: { color: "#cdd6f4", wordBreak: "break-all" as const },
};
