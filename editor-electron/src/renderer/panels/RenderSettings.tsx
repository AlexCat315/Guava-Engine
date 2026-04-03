import React, { useEffect, useState, useCallback, useRef } from "react";
import type { RpcResult } from "../../shared/rpc-types";
import { useI18n } from "../i18n";

type RenderSettings = RpcResult<"viewport.getRenderSettings">;
type ShadingMode = "solid" | "material" | "rendered" | "wireframe";

interface RenderSettingsProps {
  connected: boolean;
}

export function RenderSettingsPanel({ connected }: RenderSettingsProps) {
  const { t } = useI18n();
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
    return <div style={styles.container}><div style={styles.empty}>{t.common.notConnected}</div></div>;
  }

  const shadingLabels: Record<ShadingMode, string> = {
    solid: t.renderSettings.solid,
    material: t.renderSettings.material,
    rendered: t.renderSettings.rendered,
    wireframe: t.renderSettings.wireframe,
  };

  return (
    <div style={styles.container}>
      <div style={styles.header}>{t.renderSettings.title}</div>

      {/* Shading Mode */}
      <Section title={t.renderSettings.shading}>
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
              {shadingLabels[mode]}
            </button>
          ))}
        </div>
      </Section>

      {/* Viewport Overlays */}
      <Section title={t.renderSettings.overlays}>
        <Toggle label={t.renderSettings.grid} value={settings.showGrid} onChange={(v) => commit({ showGrid: v })} />
        <Toggle label={t.renderSettings.bones} value={settings.showBones} onChange={(v) => commit({ showBones: v })} />
        <Toggle label={t.renderSettings.collision} value={settings.showCollision} onChange={(v) => commit({ showCollision: v })} />
      </Section>

      {/* Post-Processing */}
      <Section title={t.renderSettings.postProcessing}>
        <ToggleSlider
          label={t.renderSettings.bloom}
          enabled={settings.bloomEnabled}
          onToggle={(v) => commit({ bloomEnabled: v })}
          sliders={[
            { label: t.renderSettings.threshold, value: settings.bloomThreshold, min: 0, max: 5, step: 0.1, onChange: (v) => commit({ bloomThreshold: v }) },
            { label: t.renderSettings.intensity, value: settings.bloomIntensity, min: 0, max: 2, step: 0.05, onChange: (v) => commit({ bloomIntensity: v }) },
          ]}
        />
        <ToggleSlider
          label={t.renderSettings.exposure}
          enabled={settings.exposureEnabled}
          onToggle={(v) => commit({ exposureEnabled: v })}
          sliders={[
            { label: t.renderSettings.value, value: settings.exposure, min: 0.1, max: 10, step: 0.1, onChange: (v) => commit({ exposure: v }) },
          ]}
        />
        <ToggleSlider
          label={t.renderSettings.ssao}
          enabled={settings.ssaoEnabled}
          onToggle={(v) => commit({ ssaoEnabled: v })}
          sliders={[
            { label: t.renderSettings.radius, value: settings.ssaoRadius, min: 0.1, max: 5, step: 0.1, onChange: (v) => commit({ ssaoRadius: v }) },
            { label: t.renderSettings.intensity, value: settings.ssaoIntensity, min: 0, max: 3, step: 0.1, onChange: (v) => commit({ ssaoIntensity: v }) },
          ]}
        />
        <ToggleSlider
          label={t.renderSettings.dof}
          enabled={settings.dofEnabled}
          onToggle={(v) => commit({ dofEnabled: v })}
          sliders={[
            { label: t.renderSettings.focusDist, value: settings.dofFocusDistance, min: 0.1, max: 100, step: 0.5, onChange: (v) => commit({ dofFocusDistance: v }) },
            { label: t.renderSettings.focusRange, value: settings.dofFocusRange, min: 0.1, max: 50, step: 0.5, onChange: (v) => commit({ dofFocusRange: v }) },
          ]}
        />
        <Toggle label={t.renderSettings.fxaa} value={settings.fxaaEnabled} onChange={(v) => commit({ fxaaEnabled: v })} />
        <Toggle label={t.renderSettings.taa} value={settings.taaEnabled} onChange={(v) => commit({ taaEnabled: v })} />
        <Toggle label={t.renderSettings.contactShadows} value={settings.contactShadowsEnabled} onChange={(v) => commit({ contactShadowsEnabled: v })} />
      </Section>

      {/* Color Grading */}
      <Section title={t.renderSettings.colorGrading}>
        <ToggleSlider
          label={t.renderSettings.colorGrading}
          enabled={settings.colorGradingEnabled}
          onToggle={(v) => commit({ colorGradingEnabled: v })}
          sliders={[
            { label: t.renderSettings.saturation, value: settings.colorGradingSaturation, min: 0, max: 3, step: 0.05, onChange: (v) => commit({ colorGradingSaturation: v }) },
            { label: t.renderSettings.contrast, value: settings.colorGradingContrast, min: 0, max: 3, step: 0.05, onChange: (v) => commit({ colorGradingContrast: v }) },
            { label: t.renderSettings.gamma, value: settings.colorGradingGamma, min: 0.1, max: 3, step: 0.05, onChange: (v) => commit({ colorGradingGamma: v }) },
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
