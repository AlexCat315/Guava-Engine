import React, { useEffect, useState, useCallback, useRef } from "react";
import type { Transform, ComponentInfo, Vec3 } from "../../shared/rpc-types";

interface InspectorProps {
  entityId: number | null;
}

export function Inspector({ entityId }: InspectorProps) {
  const [transform, setTransform] = useState<Transform | null>(null);
  const [components, setComponents] = useState<ComponentInfo[]>([]);
  const [entityName, setEntityName] = useState("");
  const [collapsedSections, setCollapsedSections] = useState<Set<string>>(new Set());

  const fetchEntityData = useCallback(async (eid: number) => {
    try {
      const [t, c] = await Promise.all([
        window.guavaEngine.call("entity.getTransform", { entityId: eid }) as Promise<Transform>,
        window.guavaEngine.call("entity.getComponents", { entityId: eid }) as Promise<{ components: ComponentInfo[] }>,
      ]);
      setTransform(t);
      setComponents(c.components);
    } catch {
      // Entity may have been removed
    }
  }, []);

  useEffect(() => {
    if (entityId == null) {
      setTransform(null);
      setComponents([]);
      setEntityName("");
      return;
    }
    fetchEntityData(entityId);
  }, [entityId, fetchEntityData]);

  const commitName = useCallback(() => {
    if (entityId != null && entityName.trim()) {
      window.guavaEngine.call("entity.setName", { entityId, name: entityName });
    }
  }, [entityId, entityName]);

  const commitTransform = useCallback(
    (partial: Partial<Transform>) => {
      if (entityId == null) return;
      window.guavaEngine.call("entity.setTransform", { entityId, transform: partial });
    },
    [entityId],
  );

  const toggleSection = (key: string) => {
    setCollapsedSections((prev) => {
      const next = new Set(prev);
      next.has(key) ? next.delete(key) : next.add(key);
      return next;
    });
  };

  if (entityId == null) {
    return (
      <div style={styles.container}>
        <div style={styles.header}>Inspector</div>
        <div style={styles.empty}>No entity selected</div>
      </div>
    );
  }

  return (
    <div style={styles.container}>
      <div style={styles.header}>Inspector</div>

      {/* Entity identity */}
      <div style={styles.section}>
        <div style={styles.sectionTitle}>Entity #{entityId}</div>
        <div style={styles.field}>
          <label style={styles.label}>Name</label>
          <input
            type="text"
            value={entityName}
            onChange={(e) => setEntityName(e.target.value)}
            onBlur={commitName}
            onKeyDown={(e) => e.key === "Enter" && commitName()}
            style={styles.input}
            placeholder="Entity name"
          />
        </div>
      </div>

      {/* Transform */}
      {transform && (
        <CollapsibleSection
          title="Transform"
          collapsed={collapsedSections.has("transform")}
          onToggle={() => toggleSection("transform")}
        >
          <Vec3Input
            label="Position"
            value={transform.position}
            step={0.1}
            onChange={(v) => {
              setTransform((t) => t && { ...t, position: v });
              commitTransform({ position: v });
            }}
          />
          <Vec3Input
            label="Rotation"
            value={transform.rotation}
            step={1}
            onChange={(v) => {
              setTransform((t) => t && { ...t, rotation: v });
              commitTransform({ rotation: v });
            }}
          />
          <Vec3Input
            label="Scale"
            value={transform.scale}
            step={0.1}
            onChange={(v) => {
              setTransform((t) => t && { ...t, scale: v });
              commitTransform({ scale: v });
            }}
          />
        </CollapsibleSection>
      )}

      {/* Components */}
      {components.map((comp) => (
        <CollapsibleSection
          key={comp.type}
          title={comp.type}
          collapsed={collapsedSections.has(comp.type)}
          onToggle={() => toggleSection(comp.type)}
        >
          {comp.fields.length === 0 ? (
            <div style={{ ...styles.empty, padding: 8 }}>No editable fields</div>
          ) : (
            comp.fields.map((field) => (
              <div key={field.name} style={styles.field}>
                <label style={styles.label}>{field.name}</label>
                <span style={styles.value}>{formatFieldValue(field.value)}</span>
              </div>
            ))
          )}
        </CollapsibleSection>
      ))}
    </div>
  );
}

// ── Collapsible section ──────────────────────────────────────────

function CollapsibleSection({
  title,
  collapsed,
  onToggle,
  children,
}: {
  title: string;
  collapsed: boolean;
  onToggle: () => void;
  children: React.ReactNode;
}) {
  return (
    <div style={styles.section}>
      <div style={styles.sectionHeader} onClick={onToggle}>
        <span style={styles.arrow}>{collapsed ? "▸" : "▾"}</span>
        <span style={styles.sectionTitle}>{title}</span>
      </div>
      {!collapsed && children}
    </div>
  );
}

// ── Editable Vec3 input ──────────────────────────────────────────

const AXES: { key: keyof Vec3; color: string; label: string }[] = [
  { key: "x", color: "#f38ba8", label: "X" },
  { key: "y", color: "#a6e3a1", label: "Y" },
  { key: "z", color: "#89b4fa", label: "Z" },
];

function Vec3Input({
  label,
  value,
  step = 0.1,
  onChange,
}: {
  label: string;
  value: Vec3;
  step?: number;
  onChange: (v: Vec3) => void;
}) {
  const [local, setLocal] = useState(value);
  const commitTimer = useRef<ReturnType<typeof setTimeout>>();

  // Sync with external value when entity changes
  useEffect(() => {
    setLocal(value);
  }, [value.x, value.y, value.z]);

  const handleChange = (axis: keyof Vec3, raw: string) => {
    const n = parseFloat(raw);
    if (isNaN(n)) return;
    const next = { ...local, [axis]: n };
    setLocal(next);
    // Debounce RPC calls (150ms)
    clearTimeout(commitTimer.current);
    commitTimer.current = setTimeout(() => onChange(next), 150);
  };

  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <div style={styles.vec3}>
        {AXES.map(({ key, color, label: axisLabel }) => (
          <div key={key} style={styles.axisGroup}>
            <span style={{ color, fontSize: 10, fontWeight: 700 }}>{axisLabel}</span>
            <input
              type="number"
              step={step}
              value={local[key].toFixed(step < 1 ? 2 : 0)}
              onChange={(e) => handleChange(key, e.target.value)}
              style={styles.numInput}
            />
          </div>
        ))}
      </div>
    </div>
  );
}

// ── Helpers ──────────────────────────────────────────────────────

function formatFieldValue(value: unknown): string {
  if (value == null) return "null";
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

// ── Styles ──────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column" },
  header: {
    padding: "8px 12px",
    borderBottom: "1px solid #313244",
    fontSize: 12,
    fontWeight: 600,
    textTransform: "uppercase",
    letterSpacing: 0.5,
    color: "#a6adc8",
  },
  empty: { padding: 24, textAlign: "center", opacity: 0.4, fontSize: 13 },
  section: {
    borderBottom: "1px solid #313244",
    padding: "6px 12px",
  },
  sectionHeader: {
    display: "flex",
    alignItems: "center",
    gap: 4,
    cursor: "pointer",
    userSelect: "none",
    marginBottom: 4,
  },
  sectionTitle: {
    fontSize: 12,
    fontWeight: 600,
    color: "#cdd6f4",
  },
  arrow: {
    fontSize: 10,
    color: "#6c7086",
    width: 12,
  },
  field: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    padding: "3px 0",
    fontSize: 12,
  },
  label: {
    color: "#a6adc8",
    minWidth: 70,
    fontSize: 11,
  },
  value: {
    color: "#cdd6f4",
    fontSize: 12,
    fontFamily: "monospace",
  },
  vec3: {
    display: "flex",
    gap: 4,
    alignItems: "center",
    flex: 1,
    marginLeft: 8,
  },
  axisGroup: {
    display: "flex",
    alignItems: "center",
    gap: 2,
    flex: 1,
  },
  numInput: {
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    padding: "2px 4px",
    fontSize: 11,
    fontFamily: "monospace",
    width: "100%",
    outline: "none",
  },
  input: {
    background: "#313244",
    border: "1px solid #45475a",
    borderRadius: 3,
    color: "#cdd6f4",
    padding: "2px 6px",
    fontSize: 12,
    flex: 1,
    marginLeft: 8,
    outline: "none",
  },
};
