/**
 * JSON-RPC 2.0 base types for engine ↔ editor communication.
 */

// ── JSON-RPC 2.0 Wire Format ──────────────────────────────────────

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number | string;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcNotification {
  jsonrpc: "2.0";
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number | string;
  result?: unknown;
  error?: JsonRpcError;
}

export interface JsonRpcError {
  code: number;
  message: string;
  data?: unknown;
}

// ── Error Codes (matches protocol.zig ErrorCode) ───────────────────

export const ErrorCode = {
  ParseError: -32700,
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,
  ResourceNotFound: -32002,
} as const;

// ── RPC Method Signatures ──────────────────────────────────────────

/** Type-safe method definitions: method name → { params, result } */
export interface RpcMethods {
  // Lifecycle
  "editor.ping": { params: {}; result: { pong: true } };
  "editor.getCapabilities": {
    params: {};
    result: {
      version: string;
      methods: string[];
      subscriptions: string[];
    };
  };

  // Scene hierarchy
  "scene.getHierarchy": {
    params: {};
    result: { roots: EntityNode[] };
  };
  "scene.createEntity": {
    params: { name?: string; parentId?: number };
    result: { entityId: number };
  };
  "scene.deleteEntity": {
    params: { entityId: number };
    result: {};
  };
  "scene.reparent": {
    params: { entityId: number; newParentId: number | null };
    result: {};
  };
  "scene.duplicateEntity": {
    params: { entityId: number };
    result: { entityId: number };
  };

  // Entity inspection
  "entity.getComponents": {
    params: { entityId: number };
    result: { components: ComponentInfo[] };
  };
  "entity.getTransform": {
    params: { entityId: number };
    result: Transform;
  };
  "entity.setTransform": {
    params: { entityId: number; transform: Partial<Transform> };
    result: {};
  };
  "entity.setName": {
    params: { entityId: number; name: string };
    result: {};
  };

  // Component CRUD
  "component.add": {
    params: { entityId: number; componentType: string; data?: Record<string, unknown> };
    result: {};
  };
  "component.remove": {
    params: { entityId: number; componentType: string };
    result: {};
  };
  "component.update": {
    params: { entityId: number; componentType: string; field: string; value: unknown };
    result: {};
  };

  // Asset browser
  "asset.listDirectory": {
    params: { path: string };
    result: { entries: AssetEntry[] };
  };
  "asset.getMetadata": {
    params: { assetId: string };
    result: AssetMetadata;
  };
  "asset.import": {
    params: { sourcePath: string; targetDir: string };
    result: { assetId: string };
  };

  // Editor state
  "editor.getState": {
    params: {};
    result: EditorStateSnapshot;
  };
  "editor.setSelection": {
    params: { entityIds: number[] };
    result: {};
  };
  "editor.undo": {
    params: {};
    result: {};
  };
  "editor.redo": {
    params: {};
    result: {};
  };

  // Viewport control
  "viewport.resize": {
    params: { width: number; height: number };
    result: {};
  };
  "viewport.setRenderMode": {
    params: { mode: RenderMode };
    result: {};
  };
  "viewport.setGizmoMode": {
    params: { mode: GizmoMode };
    result: {};
  };
  "viewport.setCameraTransform": {
    params: { position: Vec3; rotation: Vec3 };
    result: {};
  };

  // Playback
  "playback.play": { params: {}; result: {} };
  "playback.pause": { params: {}; result: {} };
  "playback.stop": { params: {}; result: {} };

  // Console
  "console.getLogs": {
    params: { offset?: number; limit?: number };
    result: { logs: LogEntry[]; total: number };
  };
  "console.clear": { params: {}; result: {} };
}

// ── Subscription Event Types ───────────────────────────────────────

export interface SubscriptionEvents {
  "on:scene.changed": { revision: number; entityIds: number[] };
  "on:selection.changed": { entityIds: number[] };
  "on:viewport.metrics": { fps: number; drawCalls: number; triangles: number };
  "on:console.log": LogEntry;
  "on:playback.stateChanged": { state: "playing" | "paused" | "stopped" };
  "on:asset.changed": { assetId: string; changeType: "created" | "modified" | "deleted" };
}

// ── Data Model Types ───────────────────────────────────────────────

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

export interface Transform {
  position: Vec3;
  rotation: Vec3; // Euler angles in degrees
  scale: Vec3;
}

export interface EntityNode {
  id: number;
  name: string;
  visible: boolean;
  locked: boolean;
  children: EntityNode[];
  componentTypes: string[];
}

export interface ComponentInfo {
  type: string;
  fields: ComponentField[];
}

export interface ComponentField {
  name: string;
  fieldType: FieldType;
  value: unknown;
  min?: number;
  max?: number;
  step?: number;
}

export type FieldType =
  | "float"
  | "int"
  | "bool"
  | "string"
  | "vec3"
  | "vec4"
  | "color"
  | "enum"
  | "asset_ref"
  | "entity_ref";

export interface AssetEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  assetType?: AssetType;
  size?: number;
  modifiedTime?: number;
}

export type AssetType =
  | "model"
  | "texture"
  | "material"
  | "scene"
  | "script"
  | "shader"
  | "audio"
  | "prefab"
  | "animation";

export interface AssetMetadata {
  id: string;
  name: string;
  type: AssetType;
  path: string;
  size: number;
  dependencies: string[];
}

export interface EditorStateSnapshot {
  selectedEntities: number[];
  renderMode: RenderMode;
  gizmoMode: GizmoMode;
  transformSpace: "local" | "world";
  playbackState: "playing" | "paused" | "stopped";
  cameraPosition: Vec3;
  cameraRotation: Vec3;
  vsyncEnabled: boolean;
  panelStates: Record<string, boolean>;
}

export type RenderMode = "textured" | "wireframe" | "unlit" | "normals" | "depth";
export type GizmoMode = "translate" | "rotate" | "scale" | "none";

export interface LogEntry {
  level: "debug" | "info" | "warn" | "error";
  message: string;
  timestamp: number;
  source?: string;
}
