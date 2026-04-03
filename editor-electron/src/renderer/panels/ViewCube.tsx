import React, { useRef, useEffect, useCallback, useState } from "react";

interface ViewCubeProps {
  connected: boolean;
}

// Face definitions: label, axis direction (camera looks ALONG this direction to see the face)
const FACES = [
  { label: "Front", axis: [0, 0, -1] },
  { label: "Back", axis: [0, 0, 1] },
  { label: "Left", axis: [1, 0, 0] },
  { label: "Right", axis: [-1, 0, 0] },
  { label: "Top", axis: [0, -1, 0] },
  { label: "Bottom", axis: [0, 1, 0] },
] as const;

type Vec3 = [number, number, number];
type Quat = [number, number, number, number]; // x,y,z,w

// Quaternion → rotation matrix (column-major 3x3)
function quatToMat3(q: Quat): number[] {
  const [x, y, z, w] = q;
  const x2 = x + x, y2 = y + y, z2 = z + z;
  const xx = x * x2, xy = x * y2, xz = x * z2;
  const yy = y * y2, yz = y * z2, zz = z * z2;
  const wx = w * x2, wy = w * y2, wz = w * z2;
  return [
    1 - yy - zz, xy + wz, xz - wy,
    xy - wz, 1 - xx - zz, yz + wx,
    xz + wy, yz - wx, 1 - xx - yy,
  ];
}

// Apply 3x3 rotation matrix to a 3D point
function applyMat3(m: number[], v: Vec3): Vec3 {
  return [
    m[0] * v[0] + m[3] * v[1] + m[6] * v[2],
    m[1] * v[0] + m[4] * v[1] + m[7] * v[2],
    m[2] * v[0] + m[5] * v[1] + m[8] * v[2],
  ];
}

// Cube vertices (unit cube centered at origin)
const S = 0.38;
const VERTS: Vec3[] = [
  [-S, -S, -S], [S, -S, -S], [S, S, -S], [-S, S, -S], // front face (z = -S)
  [-S, -S, S], [S, -S, S], [S, S, S], [-S, S, S],     // back face (z = +S)
];

// Face quads: [v0, v1, v2, v3] indices (CCW from outside)
const FACE_QUADS = [
  [0, 1, 2, 3], // Front (z=-S)
  [5, 4, 7, 6], // Back  (z=+S)
  [4, 0, 3, 7], // Left  (x=-S)
  [1, 5, 6, 2], // Right (x=+S)
  [3, 2, 6, 7], // Top   (y=+S)
  [4, 5, 1, 0], // Bottom(y=-S)
];

const FACE_COLORS = [
  "rgba(89,180,250,0.5)",   // Front - blue
  "rgba(89,180,250,0.35)",  // Back
  "rgba(166,173,200,0.4)",  // Left - gray
  "rgba(166,173,200,0.4)",  // Right
  "rgba(137,180,250,0.45)", // Top - lighter blue
  "rgba(137,180,250,0.3)",  // Bottom
];

const AXIS_COLORS: Record<string, string> = {
  X: "#f38ba8", // red
  Y: "#a6e3a1", // green
  Z: "#89b4fa", // blue
};

const SIZE = 90; // Canvas size in CSS pixels
const DPR = typeof window !== "undefined" ? window.devicePixelRatio || 1 : 1;

export function ViewCube({ connected }: ViewCubeProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const rotRef = useRef<Quat>([0, 0, 0, 1]); // camera rotation quaternion
  const dragRef = useRef<{ startX: number; startY: number; dragging: boolean }>({ startX: 0, startY: 0, dragging: false });
  const [, forceUpdate] = useState(0);

  // Poll camera state
  useEffect(() => {
    if (!connected) return;
    let cancelled = false;
    const poll = async () => {
      while (!cancelled) {
        try {
          const res = await window.guavaEngine.call("camera.getState", {});
          if (res.rotation) {
            rotRef.current = [res.rotation.x, res.rotation.y, res.rotation.z, res.rotation.w];
            forceUpdate((n) => n + 1);
          }
        } catch { /* engine not ready */ }
        await new Promise((r) => setTimeout(r, 100));
      }
    };
    poll();
    return () => { cancelled = true; };
  }, [connected]);

  // Draw cube
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const w = SIZE * DPR;
    const h = SIZE * DPR;
    canvas.width = w;
    canvas.height = h;
    ctx.clearRect(0, 0, w, h);

    const rot = rotRef.current;
    const mat = quatToMat3(rot);

    // Project 3D → 2D (orthographic with slight perspective)
    const cx = w / 2;
    const cy = h / 2;
    const scale = w * 0.85;

    const project = (v: Vec3): [number, number] => {
      const r = applyMat3(mat, v);
      return [cx + r[0] * scale, cy - r[1] * scale];
    };

    // Compute face depths for painter's algorithm (sort back-to-front)
    const faceDepths = FACE_QUADS.map((quad, i) => {
      const center: Vec3 = [0, 0, 0];
      for (const vi of quad) {
        center[0] += VERTS[vi][0];
        center[1] += VERTS[vi][1];
        center[2] += VERTS[vi][2];
      }
      center[0] /= 4;
      center[1] /= 4;
      center[2] /= 4;
      const rotated = applyMat3(mat, center);
      return { index: i, depth: rotated[2] };
    }).sort((a, b) => a.depth - b.depth); // back first

    // Draw faces
    for (const { index } of faceDepths) {
      const quad = FACE_QUADS[index];
      const pts = quad.map((vi) => project(VERTS[vi]));

      // Check facing (only draw front-faces or semi-transparent back-faces)
      ctx.beginPath();
      ctx.moveTo(pts[0][0], pts[0][1]);
      for (let j = 1; j < pts.length; j++) ctx.lineTo(pts[j][0], pts[j][1]);
      ctx.closePath();

      ctx.fillStyle = FACE_COLORS[index];
      ctx.fill();
      ctx.strokeStyle = "rgba(205,214,244,0.3)";
      ctx.lineWidth = DPR;
      ctx.stroke();

      // Draw face label
      const center = applyMat3(mat, [
        VERTS[quad[0]][0] / 4 + VERTS[quad[1]][0] / 4 + VERTS[quad[2]][0] / 4 + VERTS[quad[3]][0] / 4,
        VERTS[quad[0]][1] / 4 + VERTS[quad[1]][1] / 4 + VERTS[quad[2]][1] / 4 + VERTS[quad[3]][1] / 4,
        VERTS[quad[0]][2] / 4 + VERTS[quad[1]][2] / 4 + VERTS[quad[2]][2] / 4 + VERTS[quad[3]][2] / 4,
      ]);
      // Only label facing-toward-camera faces (z > 0 means facing us)
      if (center[2] > 0) {
        const lp = project([
          (VERTS[quad[0]][0] + VERTS[quad[1]][0] + VERTS[quad[2]][0] + VERTS[quad[3]][0]) / 4,
          (VERTS[quad[0]][1] + VERTS[quad[1]][1] + VERTS[quad[2]][1] + VERTS[quad[3]][1]) / 4,
          (VERTS[quad[0]][2] + VERTS[quad[1]][2] + VERTS[quad[2]][2] + VERTS[quad[3]][2]) / 4,
        ]);
        ctx.fillStyle = `rgba(205,214,244,${Math.min(center[2] * 3, 0.9)})`;
        ctx.font = `bold ${10 * DPR}px system-ui`;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillText(FACES[index].label, lp[0], lp[1]);
      }
    }

    // Draw axis indicators
    const axisLen = 0.45;
    const axes: [string, Vec3][] = [
      ["X", [axisLen, 0, 0]],
      ["Y", [0, axisLen, 0]],
      ["Z", [0, 0, axisLen]],
    ];
    const origin = project([0, 0, 0]);
    for (const [name, dir] of axes) {
      const end = project(dir);
      ctx.beginPath();
      ctx.moveTo(origin[0], origin[1]);
      ctx.lineTo(end[0], end[1]);
      ctx.strokeStyle = AXIS_COLORS[name];
      ctx.lineWidth = 2 * DPR;
      ctx.stroke();

      // Axis label
      ctx.fillStyle = AXIS_COLORS[name];
      ctx.font = `bold ${9 * DPR}px system-ui`;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(name, end[0], end[1] - 6 * DPR);
    }
  });

  // Click handler: detect which face was clicked
  const handleClick = useCallback((e: React.MouseEvent) => {
    if (!connected || dragRef.current.dragging) return;

    const canvas = canvasRef.current;
    if (!canvas) return;
    const rect = canvas.getBoundingClientRect();
    const mx = (e.clientX - rect.left) / rect.width * 2 - 1; // -1..1
    const my = -((e.clientY - rect.top) / rect.height * 2 - 1); // -1..1 (Y up)

    const rot = rotRef.current;
    const mat = quatToMat3(rot);

    // Find the face whose projected center is closest to click and faces camera
    let bestFace = -1;
    let bestDist = Infinity;

    for (let i = 0; i < FACES.length; i++) {
      const quad = FACE_QUADS[i];
      const center: Vec3 = [
        (VERTS[quad[0]][0] + VERTS[quad[1]][0] + VERTS[quad[2]][0] + VERTS[quad[3]][0]) / 4,
        (VERTS[quad[0]][1] + VERTS[quad[1]][1] + VERTS[quad[2]][1] + VERTS[quad[3]][1]) / 4,
        (VERTS[quad[0]][2] + VERTS[quad[1]][2] + VERTS[quad[2]][2] + VERTS[quad[3]][2]) / 4,
      ];
      const rotated = applyMat3(mat, center);
      if (rotated[2] < 0) continue; // facing away

      const px = rotated[0] / 0.5; // normalize to -1..1 range
      const py = rotated[1] / 0.5;
      const dist = (px - mx) * (px - mx) + (py - my) * (py - my);
      if (dist < bestDist && dist < 0.5) {
        bestDist = dist;
        bestFace = i;
      }
    }

    if (bestFace >= 0) {
      const face = FACES[bestFace];
      window.guavaEngine.call("camera.lookAlongAxis", {
        axisX: face.axis[0],
        axisY: face.axis[1],
        axisZ: face.axis[2],
      } as never).catch(() => {});
    }
  }, [connected]);

  // Drag handler: orbit camera
  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    dragRef.current = { startX: e.clientX, startY: e.clientY, dragging: false };

    const onMove = (ev: MouseEvent) => {
      const dx = ev.clientX - dragRef.current.startX;
      const dy = ev.clientY - dragRef.current.startY;
      if (!dragRef.current.dragging && dx * dx + dy * dy > 9) {
        dragRef.current.dragging = true;
      }
      if (dragRef.current.dragging) {
        const sensitivity = 0.008;
        window.guavaEngine.call("camera.orbit", {
          deltaYaw: -(ev.clientX - dragRef.current.startX) * sensitivity,
          deltaPitch: (ev.clientY - dragRef.current.startY) * sensitivity,
        } as never).catch(() => {});
        dragRef.current.startX = ev.clientX;
        dragRef.current.startY = ev.clientY;
      }
    };

    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };

    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  }, []);

  if (!connected) return null;

  return (
    <canvas
      ref={canvasRef}
      width={SIZE * DPR}
      height={SIZE * DPR}
      style={styles.canvas}
      onClick={handleClick}
      onMouseDown={handleMouseDown}
    />
  );
}

const styles: Record<string, React.CSSProperties> = {
  canvas: {
    width: SIZE,
    height: SIZE,
    cursor: "pointer",
    borderRadius: 6,
    background: "rgba(24,24,37,0.6)",
    border: "1px solid #313244",
  },
};
