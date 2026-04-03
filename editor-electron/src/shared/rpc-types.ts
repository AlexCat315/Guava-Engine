/**
 * RPC type barrel — re-exports auto-generated types + frontend-only types.
 *
 * Auto-generated types come from rpc-types.generated.ts (source: rpc_schema.zig).
 * Manual types below are frontend-only and not part of the engine schema.
 */

// ── Re-export everything from the generated schema ─────────────────

export type {
  Vec3,
  Quat,
  Transform,
  TransformPartial,
  EntityNode,
  ComponentInfo,
  LogEntry,
  AssetEntry,
  RpcMethods,
  SubscriptionEvents,
  RpcMethodName,
  SubscriptionName,
  RpcParams,
  RpcResult,
  JsonRpcRequest,
  JsonRpcResponse,
} from "./rpc-types.generated";

// ── Frontend-only types (not in engine schema) ─────────────────────

export type GizmoMode = "translate" | "rotate" | "scale" | "none";
export type RenderMode = "textured" | "wireframe" | "unlit" | "normals" | "depth";

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

export interface ComponentField {
  name: string;
  fieldType: FieldType;
  value: unknown;
  min?: number;
  max?: number;
  step?: number;
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

export const ErrorCode = {
  ParseError: -32700,
  InvalidRequest: -32600,
  MethodNotFound: -32601,
  InvalidParams: -32602,
  InternalError: -32603,
  ResourceNotFound: -32002,
} as const;
