import React, { useEffect, useState, useCallback, useRef } from "react";
import type { RpcResult } from "../../shared/rpc-types";

type RenderSettings = RpcResult<"viewport.getRenderSettings">;
type ShadingMode = "solid" | "material" | "rendered" | "wireframe";

interface RenderSettingsProps {
  connected: boolean;
}

export function RenderSettingsPanel({ connected }: RenderSettingsProps) {
  const [settings, setSettings] = useState<RenderSettings | null>(null);
  const commitTimer = useRef<ReturnType<typeof setTimeout>>();

  const fetchSettings = useCallback(async () => {
    if (!connected) return;
    try {
      const result = await window.guavaEngine.call("viewport.getRenderSettings", {});
      setSettings(result);
    } catch {
      // ignore
    }
  }, [connected]);

  useEffect(() => {
    fetchSettings();
  }, [fetchSettings]);

  const commit = useCallback(
    (partial: Record<string, unknown>) => {
      setSettings((prev) => (prev ? { ...prev, ...partial } : prev));
      clearTimeout(commitTimer.current);
      commitTimer.current = setTimeout(() => {
        window.guavaEngine.call("viewport.setRenderSettings", partial as never).catch(() => {});
      }, 80);
    },
    [],
  );

  if (!connected || !settings) {
    return <div style={styles.container}><div style={styles.empty}>Not connected</div></div>;
  }

  return (
    <div style={styles.container}>
      <div style={styles.header}>Render Settings</div>

      {/* Shading Mode */}
      <Section title="Shading">
        <div style={styles.buttonGroup}>
          {(["solid", "material", "rendered", "wireframe"] as ShadingMode[]).map((mode) => (
            <button
              key={mode}
              style={{
                ...styles.modeButton,
                ...(settings.shadingMode === mode ? styles.modeButtonActive : {}),
              }}
              onClick={() => commit({ shadingMode: mode })}
            >
              {mode.charAt(0).toUpperCase() + mode.slice(1)}
            </button>
          ))}
        </div>
      </Section>

      {/* Viewport Overlays */}
      <Section title="Overlays">
        <Toggle label="Grid" value={settings.showGrid} onChange={(v) => commit({ showGrid: v })} />
        <Toggle label="Bones" value={settings.showBones} onChange={(v) => commit({ showBones: v })} />
        <Toggle label="Collision" value={settings.showCollision} onChange={(v) => commit({ showCollision: v })} />
      </Section>

      {/* Post-Processing */}
      <Section title="Post-Processing">
        <ToggleSlider
          label="Bloom"
          enabled={settings.bloomEnabled}
          onToggle={(v) => commit({ bloomEnabled: v })}
          sliders={[
            { label: "Threshold", value: settings.bloomThreshold, min: 0, max: 5, step: 0.1, onChange: (v) => commit({ bloomThreshold: v }) },
            { label: "Intensity", value: settings.bloomIntensity, min: 0, max: 2, step: 0.05, onChange: (v) => commit({ bloomIntensity: v }) },
          ]}
        />
        <ToggleSlider
          label="Exposure"
          enabled={settings.exposureEnabled}
          onToggle={(v) => commit({ exposureEnabled: v })}
          sliders={[
            { label: "Value", value: settings.exposure, min: 0.1, max: 10, step: 0.1, onChange: (v) => commit({ exposure: v }) },
          ]}
        />
        <ToggleSlider
          label="SSAO"
          enabled={settings.ssaoEnabled}
          onToggle={(v) => commit({ ssaoEnabled: v })}
          sliders={[
            { label: "Radius", value: settings.ssaoRadius, min: 0.1, max: 5, step: 0.1, onChange: (v) => commit({ ssaoRadius: v }) },
            { label: "Intensity", value: settings.ssaoIntensity, min: 0, max: 3, step: 0.1, onChange: (v) => commit({ ssaoIntensity: v }) },
          ]}
        />
        <ToggleSlider
          label="DOF"
          enabled={settings.dofEnabled}
          onToggle={(v) => commit({ dofEnabled: v })}
          sliders={[
            { label: "Focus Dist", value: settings.dofFocusDistance, min: 0.1, max: 100, step: 0.5, onChange: (v) => commit({ dofFocusDistance: v }) },
            { label: "Focus Range", value: settings.dofFocusRange, min: 0.1, max: 50, step: 0.5, onChange: (v) => commit({ dofFocusRange: v }) },
          ]}
        />
        <Toggle label="FXAA" value={settings.fxaaEnabled} onChange={(v) => commit({ fxaaEnabled: v })} />
        <Toggle label="TAA" value={settings.taaEnabled} onChange={(v) => commit({ taaEnabled: v })} />
        <Toggle label="Contact Shadows" value={settings.contactShadowsEnabled} onChange={(v) => commit({ contactShadowsEnabled: v })} />
      </Section>

      {/* Color Grading */}
      <Section title="Color Grading">
        <ToggleSlider
          label="Color Grading"
          enabled={settings.colorGradingEnabled}
          onToggle={(v) => commit({ colorGradingEnabled: v })}
          sliders={[
            { label: "Saturation", value: settings.colorGradingSaturation, min: 0, max: 3, step: 0.05, onChange: (v) => commit({ colorGradingSaturation: v }) },
            { label: "Contrast", value: settings.colorGradingContrast, min: 0, max: 3, step: 0.05, onChange: (v) => commit({ colorGradingContrast: v }) },
            { label: "Gamma", value: settings.colorGradingGamma, min: 0.1, max: 3, step: 0.05, onChange: (v) => commit({ colorGradingGamma: v }) },
          ]}
        />
      </Section>
    </div>
  );
}

// ── Sub-components ───────────────────────────────────────────────

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div style={styles.section}>
      <div style={styles.sectionTitle}>{title}</div>
      {children}
    </div>
  );
}

function Toggle({ label, value, onChange }: { label: string; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <label style={styles.toggleRow}>
      <input type="checkbox" checked={value} onChange={(e) => onChange(e.target.checked)} />
      <span>{label}</span>
    </label>
  );
}

interface SliderDef {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (v: number) => void;
}

function ToggleSlider({
  label,
  enabled,
  onToggle,
  sliders,
}: {
  label: string;
  enabled: boolean;
  onToggle: (v: boolean) => void;
  sliders: SliderDef[];
}) {
  return (
    <div style={styles.toggleSliderBlock}>
      <label style={styles.toggleRow}>
        <input type="checkbox" checked={enabled} onChange={(e) => onToggle(e.target.checked)} />
        <span>{label}</span>
      </label>
      {enabled &&
        sliders.map((s) => (
          <div key={s.label} style={styles.sliderRow}>
            <span style={styles.sliderLabel}>{s.label}</span>
            <input
              type="range"
              min={s.min}
              max={s.max}
              step={s.step}
              value={s.value}
              onChange={(e) => s.onChange(parseFloat(e.target.value))}
              style={styles.slider}
            />
            <span style={styles.sliderValue}>{s.value.toFixed(2)}</span>
          </div>
        ))}
    </div>
  );
}

// ── Styles ───────────────────────────────────────────────────────

const styles: Record<string, React.CSSProperties> = {
  container: {
    padding: 8,
    color: "#cdd6f4",
    fontSize: 13,
    overflow: "auto",
    height: "100%",
  },
  header: {
    fontSize: 14,
    fontWeight: 600,
    marginBottom: 8,
    color: "#89b4fa",
  },
  empty: {
    opacity: 0.4,
    textAlign: "center",
    padding: 16,
  },
  section: {
    marginBottom: 12,
    borderBottom: "1px solid #313244",
    paddingBottom: 8,
  },
  sectionTitle: {
    fontSize: 11,
    textTransform: "uppercase" as const,
    color: "#6c7086",
    letterSpacing: 1,
    marginBottom: 6,
  },
  buttonGroup: {
    display: "flex",
    gap: 4,
  },
  modeButton: {
    flex: 1,
    padding: "4px 8px",
    border: "1px solid #45475a",
    borderRadius: 4,
    background: "#1e1e2e",
    color: "#cdd6f4",
    cursor: "pointer",
    fontSize: 11,
    textAlign: "center" as const,
  },
  modeButtonActive: {
    background: "#89b4fa",
    color: "#1e1e2e",
    borderColor: "#89b4fa",
    fontWeight: 600,
  },
  toggleRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    padding: "3px 0",
    cursor: "pointer",
  },
  toggleSliderBlock: {
    marginBottom: 4,
  },
  sliderRow: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    paddingLeft: 24,
    marginTop: 2,
  },
  sliderLabel: {
    width: 70,
    fontSize: 11,
    color: "#a6adc8",
  },
  slider: {
    flex: 1,
    height: 4,
    accentColor: "#89b4fa",
  },
  sliderValue: {
    width: 40,
    fontSize: 11,
    color: "#a6adc8",
    textAlign: "right" as const,
  },
};
