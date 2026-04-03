import React from "react";
import type { EntityNode } from "../../shared/rpc-types";

interface SceneHierarchyProps {
  roots: EntityNode[];
  selectedId: number | null;
  onSelect: (entityId: number) => void;
}

export function SceneHierarchy({ roots, selectedId, onSelect }: SceneHierarchyProps) {
  return (
    <div style={styles.container}>
      <div style={styles.header}>
        <span style={styles.title}>Scene Hierarchy</span>
      </div>
      <div style={styles.tree}>
        {roots.length === 0 ? (
          <div style={styles.empty}>No entities</div>
        ) : (
          roots.map((node) => (
            <TreeNode
              key={node.id}
              node={node}
              depth={0}
              selectedId={selectedId}
              onSelect={onSelect}
            />
          ))
        )}
      </div>
    </div>
  );
}

interface TreeNodeProps {
  node: EntityNode;
  depth: number;
  selectedId: number | null;
  onSelect: (entityId: number) => void;
}

function TreeNode({ node, depth, selectedId, onSelect }: TreeNodeProps) {
  const [expanded, setExpanded] = React.useState(true);
  const isSelected = node.id === selectedId;
  const hasChildren = node.children.length > 0;

  return (
    <div>
      <div
        style={{
          ...styles.node,
          paddingLeft: 8 + depth * 16,
          background: isSelected ? "#45475a" : "transparent",
        }}
        onClick={() => onSelect(node.id)}
      >
        {hasChildren ? (
          <span
            style={styles.arrow}
            onClick={(e) => {
              e.stopPropagation();
              setExpanded(!expanded);
            }}
          >
            {expanded ? "▾" : "▸"}
          </span>
        ) : (
          <span style={styles.arrowPlaceholder} />
        )}
        <span style={{ opacity: node.visible ? 1 : 0.4 }}>{node.name}</span>
      </div>
      {expanded &&
        hasChildren &&
        node.children.map((child) => (
          <TreeNode
            key={child.id}
            node={child}
            depth={depth + 1}
            selectedId={selectedId}
            onSelect={onSelect}
          />
        ))}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column", height: "100%" },
  header: {
    padding: "8px 12px",
    borderBottom: "1px solid #313244",
    fontSize: 12,
    fontWeight: 600,
    textTransform: "uppercase" as const,
    letterSpacing: 0.5,
    color: "#a6adc8",
  },
  title: {},
  tree: { flex: 1, overflow: "auto", padding: "4px 0" },
  empty: { padding: 16, textAlign: "center" as const, opacity: 0.4, fontSize: 13 },
  node: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    padding: "3px 8px",
    cursor: "pointer",
    fontSize: 13,
    borderRadius: 3,
    userSelect: "none" as const,
  },
  arrow: {
    width: 14,
    textAlign: "center" as const,
    cursor: "pointer",
    fontSize: 10,
    color: "#6c7086",
  },
  arrowPlaceholder: { width: 14 },
};
