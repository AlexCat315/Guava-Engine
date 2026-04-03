import React, { useEffect, useState } from "react";
import type { Transform, ComponentInfo } from "../../shared/rpc-types";

interface InspectorProps {
  entityId: number | null;
}

export function Inspector({ entityId }: InspectorProps) {
  const [transform, setTransform] = useState<Transform | null>(null);
  const [components, setComponents] = useState<ComponentInfo[]>([]);
  const [entityName, setEntityName] = useState("");

  useEffect(() => {
    if (entityId == null) {
      setTransform(null);
      setComponents([]);
      setEntityName("");
      return;
    }

    (async () => {
      try {
        const t = (await window.guavaEngine.call("entity.getTransform", {
          entityId,
        })) as Transform;
        setTransform(t);

        const c = (await window.guavaEngine.call("entity.getComponents", {
          entityId,
        })) as { components: ComponentInfo[] };
        setComponents(c.components);
      } catch {
        // Entity may not exist anymore
      }
    })();
  }, [entityId]);

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

      <div style={styles.section}>
        <div style={styles.sectionTitle}>Entity #{entityId}</div>
        <div style={styles.field}>
          <label style={styles.label}>Name</label>
          <input
            type="text"
            value={entityName}
            onChange={(e) => setEntityName(e.target.value)}
            onBlur={() => {
              if (entityName.trim()) {
                window.guavaEngine.call("entity.setName", {
                  entityId,
                  name: entityName,
                });
              }
            }}
            style={styles.input}
          />
        </div>
      </div>

      {transform && (
        <div style={styles.section}>
          <div style={styles.sectionTitle}>Transform</div>
          <Vec3Field label="Position" value={transform.position} />
          <Vec3Field label="Rotation" value={transform.rotation} />
          <Vec3Field label="Scale" value={transform.scale} />
        </div>
      )}

      {components.map((comp, i) => (
        <div key={i} style={styles.section}>
          <div style={styles.sectionTitle}>{comp.type}</div>
          {comp.fields.map((field) => (
            <div key={field.name} style={styles.field}>
              <label style={styles.label}>{field.name}</label>
              <span style={styles.value}>{String(field.value)}</span>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

function Vec3Field({
  label,
  value,
}: {
  label: string;
  value: { x: number; y: number; z: number };
}) {
  return (
    <div style={styles.field}>
      <label style={styles.label}>{label}</label>
      <div style={styles.vec3}>
        <span style={{ color: "#f38ba8" }}>X</span>
        <span style={styles.numValue}>{value.x.toFixed(2)}</span>
        <span style={{ color: "#a6e3a1" }}>Y</span>
        <span style={styles.numValue}>{value.y.toFixed(2)}</span>
        <span style={{ color: "#89b4fa" }}>Z</span>
        <span style={styles.numValue}>{value.z.toFixed(2)}</span>
      </div>
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  container: { display: "flex", flexDirection: "column" },
  header: {
    padding: "8px 12px",
    borderBottom: "1px solid #313244",
    fontSize: 12,
    fontWeight: 600,
    textTransform: "uppercase" as const,
    letterSpacing: 0.5,
    color: "#a6adc8",
  },
  empty: { padding: 24, textAlign: "center" as const, opacity: 0.4, fontSize: 13 },
  section: {
    borderBottom: "1px solid #313244",
    padding: "8px 12px",
  },
  sectionTitle: {
    fontSize: 12,
    fontWeight: 600,
    color: "#cdd6f4",
    marginBottom: 6,
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
  },
  value: {
    color: "#cdd6f4",
    fontSize: 12,
  },
  numValue: {
    color: "#cdd6f4",
    fontSize: 11,
    fontFamily: "monospace",
    minWidth: 50,
    textAlign: "right" as const,
  },
  vec3: {
    display: "flex",
    gap: 6,
    alignItems: "center",
    fontSize: 11,
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
