import React from "react";

interface IconProps {
  size?: number;
  color?: string;
  className?: string;
  style?: React.CSSProperties;
}

function svgIcon(path: string, viewBox = "0 0 24 24") {
  return function Icon({ size = 16, color = "currentColor", style, ...rest }: IconProps) {
    return (
      <svg
        width={size}
        height={size}
        viewBox={viewBox}
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        style={{ display: "inline-block", verticalAlign: "middle", flexShrink: 0, ...style }}
        {...rest}
      >
        <path d={path} fill={color} />
      </svg>
    );
  };
}

function svgIconStroke(path: string, viewBox = "0 0 24 24") {
  return function Icon({ size = 16, color = "currentColor", style, ...rest }: IconProps) {
    return (
      <svg
        width={size}
        height={size}
        viewBox={viewBox}
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
        style={{ display: "inline-block", verticalAlign: "middle", flexShrink: 0, ...style }}
        {...rest}
      >
        <path d={path} stroke={color} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
    );
  };
}

// ── File & Scene ────────────────────────────────────────────────
export const IconSave = svgIcon(
  "M17 3H5a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2V7l-4-4zm-5 16a3 3 0 110-6 3 3 0 010 6zm3-10H7V5h8v4z",
);
export const IconFolderOpen = svgIcon(
  "M2 6a2 2 0 012-2h5l2 2h9a2 2 0 012 2v1H4a2 2 0 00-2 2v6a2 2 0 002 2h16a2 2 0 002-2V8a2 2 0 00-2-2H9L7 4H4a2 2 0 00-2 2v12",
);
export const IconFolder = svgIcon(
  "M10 4H4a2 2 0 00-2 2v12a2 2 0 002 2h16a2 2 0 002-2V8a2 2 0 00-2-2h-8l-2-2z",
);

// ── Undo / Redo ─────────────────────────────────────────────────
export const IconUndo = svgIconStroke(
  "M3 10h10a5 5 0 010 10H13M3 10l4-4M3 10l4 4",
);
export const IconRedo = svgIconStroke(
  "M21 10H11a5 5 0 000 10h0M21 10l-4-4M21 10l-4 4",
);

// ── Playback ────────────────────────────────────────────────────
export const IconPlay = svgIcon("M8 5v14l11-7L8 5z");
export const IconPause = svgIcon("M6 4h4v16H6V4zm8 0h4v16h-4V4z");
export const IconStop = svgIcon("M6 6h12v12H6V6z");

// ── Gizmo / Transform ──────────────────────────────────────────
export const IconTranslate = svgIconStroke(
  "M12 2v20M2 12h20M12 2l-3 3M12 2l3 3M12 22l-3-3M12 22l3-3M2 12l3-3M2 12l3 3M22 12l-3-3M22 12l-3 3",
);
export const IconRotate = svgIconStroke(
  "M1 4v6h6M23 20v-6h-6M20.49 9A9 9 0 005.64 5.64L1 10m22 4l-4.64 4.36A9 9 0 013.51 15",
);
export const IconScale = svgIconStroke(
  "M21 3l-6.5 6.5M21 3h-5M21 3v5M3 21l6.5-6.5M3 21h5M3 21v-5",
);

// ── UI Actions ──────────────────────────────────────────────────
export const IconClose = svgIconStroke("M18 6L6 18M6 6l12 12");
export const IconRefresh = svgIconStroke(
  "M1 4v6h6M23 20v-6h-6M20.49 9A9 9 0 005.64 5.64L1 10m22 4l-4.64 4.36A9 9 0 013.51 15",
);
export const IconChevronUp = svgIconStroke("M18 15l-6-6-6 6");
export const IconChevronDown = svgIconStroke("M6 9l6 6 6-6");
export const IconChevronRight = svgIconStroke("M9 18l6-6-6-6");

// ── Asset types ─────────────────────────────────────────────────
export const IconModel = svgIcon(
  "M21 16V8a2 2 0 00-1-1.73l-7-4a2 2 0 00-2 0l-7 4A2 2 0 003 8v8a2 2 0 001 1.73l7 4a2 2 0 002 0l7-4A2 2 0 0021 16z",
);
export const IconTexture = svgIcon(
  "M19 3H5a2 2 0 00-2 2v14a2 2 0 002 2h14a2 2 0 002-2V5a2 2 0 00-2-2zM8.5 10a1.5 1.5 0 110-3 1.5 1.5 0 010 3zm12.5 9l-5-5-3 3-3-3-5 5",
);
export const IconShader = svgIconStroke(
  "M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5",
);
export const IconScene = svgIcon(
  "M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14v-4zM3 8h12v8H3V8z",
);
export const IconScript = svgIcon(
  "M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8l-6-6zm-1 1v5h5M9.5 12.5l-1.5 5M14 12l2 2.5L14 17M10 12l-2 2.5L10 17",
);
export const IconAudio = svgIconStroke(
  "M11 5L6 9H2v6h4l5 4V5zM19.07 4.93a10 10 0 010 14.14M15.54 8.46a5 5 0 010 7.08",
);
export const IconMaterial = svgIcon(
  "M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 17.93c-3.94-.49-7-3.85-7-7.93 0-.62.08-1.22.21-1.79L9 15v1a2 2 0 002 2v1.93zm6.9-2.54A1.99 1.99 0 0016 16h-1v-3a1 1 0 00-1-1H8v-2h2a1 1 0 001-1V7h2a2 2 0 002-2v-.41a7.94 7.94 0 013.9 12.8z",
);
export const IconFile = svgIcon(
  "M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8l-6-6zm-1 1v5h5",
);
export const IconArrowUp = svgIconStroke("M12 19V5M5 12l7-7 7 7");
export const IconAnimation = svgIconStroke(
  "M12 8V4H8M2 12h2M20 12h2M12 20v-2M6.34 6.34L4.93 4.93M17.66 6.34l1.41-1.41M6.34 17.66l-1.41 1.41M17.66 17.66l1.41 1.41M12 12a4 4 0 100-8 4 4 0 000 8z",
);
export const IconPrefab = svgIcon(
  "M12 2l9 4.5V17.5l-9 4.5-9-4.5V6.5L12 2zm0 15a3 3 0 100-6 3 3 0 000 6z",
);

// ── Arrow indicators ────────────────────────────────────────────
export const IconTriangleRight = svgIcon("M8 5l8 7-8 7V5z");
export const IconTriangleDown = svgIcon("M5 8l7 8 7-8H5z");
