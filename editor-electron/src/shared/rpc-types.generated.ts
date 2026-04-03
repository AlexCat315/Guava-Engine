// ╔═══════════════════════════════════════════════════════════╗
// ║  AUTO-GENERATED — do not edit manually.                  ║
// ║  Source of truth: src/engine/editor_rpc/rpc_schema.zig   ║
// ║  Regenerate:                                             ║
// ║    zig run src/engine/editor_rpc/gen_types.zig \        ║
// ║      2> editor-electron/src/shared/rpc-types.generated.ts ║
// ╚═══════════════════════════════════════════════════════════╝

// ── Data Types ─────────────────────────────────────────────

export interface Vec3 {
  x: number;
  y: number;
  z: number;
}

export interface Quat {
  x: number;
  y: number;
  z: number;
  w: number;
}

export interface Transform {
  position: Vec3;
  rotation: Quat;
  scale: Vec3;
}

export interface TransformPartial {
  position?: Vec3;
  rotation?: Quat;
  scale?: Vec3;
}

export interface EntityNode {
  id: number;
  name: string;
  visible: boolean;
  children: EntityNode[];
}

export interface ComponentInfo {
  type: string;
  fields: ComponentField[];
}

export interface ComponentField {
  name: string;
  fieldType: string;
  value: unknown;
  options?: string[];
}

export interface LogEntry {
  level: string;
  message: string;
  timestamp: number;
  source?: string;
}

export interface AssetEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  assetType?: string;
  size?: number;
}

// ── RPC Method Signatures ──────────────────────────────────

export interface RpcMethods {
  "editor.ping": { params: Record<string, never>; result: { pong: boolean } };
  "editor.getCapabilities": { params: Record<string, never>; result: { version: string; methods: string[]; subscriptions: string[] } };
  "editor.setSelection": { params: { entityIds: number[] }; result: Record<string, never> };
  "editor.undo": { params: Record<string, never>; result: Record<string, never> };
  "editor.redo": { params: Record<string, never>; result: Record<string, never> };
  "editor.getHistory": { params: Record<string, never>; result: { cursor: number; entries: { sequence: number; label: string; source: string; detail?: string; timestampMs: number }[] } };
  "editor.timeTravel": { params: { targetSequence: number }; result: Record<string, never> };
  "scene.getHierarchy": { params: Record<string, never>; result: { roots: EntityNode[] } };
  "scene.createEntity": { params: { name?: string; parentId?: number }; result: { entityId: number } };
  "scene.deleteEntity": { params: { entityId: number }; result: Record<string, never> };
  "scene.duplicateEntity": { params: { entityId: number }; result: { entityId: number } };
  "scene.save": { params: { path?: string }; result: { path: string } };
  "scene.load": { params: { path: string }; result: { path: string } };
  "scene.listScenes": { params: Record<string, never>; result: { scenes: string[] } };
  "entity.getTransform": { params: { entityId: number }; result: Transform };
  "entity.setTransform": { params: { entityId: number; transform: TransformPartial }; result: Record<string, never> };
  "entity.setName": { params: { entityId: number; name: string }; result: Record<string, never> };
  "entity.getComponents": { params: { entityId: number }; result: { components: ComponentInfo[] } };
  "entity.setComponentField": { params: { entityId: number; componentType: string; fieldName: string; value: unknown }; result: Record<string, never> };
  "entity.addComponent": { params: { entityId: number; componentType: string }; result: Record<string, never> };
  "entity.removeComponent": { params: { entityId: number; componentType: string }; result: Record<string, never> };
  "playback.play": { params: Record<string, never>; result: Record<string, never> };
  "playback.pause": { params: Record<string, never>; result: Record<string, never> };
  "playback.stop": { params: Record<string, never>; result: Record<string, never> };
  "viewport.setGizmoMode": { params: { mode: string }; result: Record<string, never> };
  "viewport.setRect": { params: { x: number; y: number; width: number; height: number }; result: Record<string, never> };
  "viewport.getWindowInfo": { params: Record<string, never>; result: { x: number; y: number; width: number; height: number; drawableWidth: number; drawableHeight: number; nativeHandle: number; platform: string } };
  "viewport.attachToParent": { params: { parentHandle: number }; result: Record<string, never> };
  "viewport.detachFromParent": { params: Record<string, never>; result: Record<string, never> };
  "viewport.getSurfaceId": { params: Record<string, never>; result: { surfaceId: number; width: number; height: number; shmName?: string } };
  "viewport.getRenderSettings": { params: Record<string, never>; result: { shadingMode: string; showGrid: boolean; showBones: boolean; showCollision: boolean; bloomEnabled: boolean; bloomThreshold: number; bloomIntensity: number; exposureEnabled: boolean; exposure: number; ssaoEnabled: boolean; ssaoRadius: number; ssaoIntensity: number; fxaaEnabled: boolean; taaEnabled: boolean; contactShadowsEnabled: boolean; colorGradingEnabled: boolean; colorGradingSaturation: number; colorGradingContrast: number; colorGradingGamma: number; dofEnabled: boolean; dofFocusDistance: number; dofFocusRange: number } };
  "viewport.setRenderSettings": { params: { shadingMode?: string; showGrid?: boolean; showBones?: boolean; showCollision?: boolean; bloomEnabled?: boolean; bloomThreshold?: number; bloomIntensity?: number; exposureEnabled?: boolean; exposure?: number; ssaoEnabled?: boolean; ssaoRadius?: number; ssaoIntensity?: number; fxaaEnabled?: boolean; taaEnabled?: boolean; contactShadowsEnabled?: boolean; colorGradingEnabled?: boolean; colorGradingSaturation?: number; colorGradingContrast?: number; colorGradingGamma?: number; dofEnabled?: boolean; dofFocusDistance?: number; dofFocusRange?: number }; result: Record<string, never> };
  "console.clear": { params: Record<string, never>; result: Record<string, never> };
  "assets.list": { params: { path?: string }; result: { path: string; entries: AssetEntry[] } };
  "camera.listBookmarks": { params: Record<string, never>; result: { bookmarks: { index: number; name: string; position: Vec3; rotation: Quat; fov: number }[] } };
  "camera.addBookmark": { params: { name?: string }; result: { index: number } };
  "camera.removeBookmark": { params: { index: number }; result: Record<string, never> };
  "camera.applyBookmark": { params: { index: number }; result: Record<string, never> };
  "camera.renameBookmark": { params: { index: number; name: string }; result: Record<string, never> };
  "debug.getRhiStats": { params: Record<string, never>; result: { bindingCache: { hits: number; misses: number; evictions: number; entries: number; maxEntries: number; hitRate: number; frameHits: number; frameMisses: number; frameEvictions: number }; passes: { name: string; status: string }[] } };
  "debug.resetRhiStats": { params: Record<string, never>; result: Record<string, never> };
  "audio.getMixerStatus": { params: Record<string, never>; result: { available: boolean; activeVoices: number; buses: { id: string; label: string; volume: number; playing: number }[] } };
  "audio.setBusVolume": { params: { busId: string; volume: number }; result: Record<string, never> };
  "plugin.list": { params: Record<string, never>; result: { plugins: { name: string; pluginType: string; source: string; lifecycle: string; lastError?: string }[] } };
  "plugin.enable": { params: { name: string }; result: Record<string, never> };
  "plugin.disable": { params: { name: string }; result: Record<string, never> };
  "plugin.unload": { params: { name: string }; result: Record<string, never> };
  "plugin.rescan": { params: { path?: string }; result: Record<string, never> };
  "style.getActiveStyle": { params: Record<string, never>; result: { name: string; displayName: string; meshProgram: string; shadowProgram?: string; source: string; path?: string; disabledPasses: string[]; configSchema: { name: string; displayName: string; paramType: string; defaultValue: number; minValue: number; maxValue: number }[]; paramValues: { name: string; value: number }[] } };
  "style.listStyles": { params: Record<string, never>; result: { styles: { name: string; displayName: string; source: string; isActive: boolean }[] } };
  "style.setActiveStyle": { params: { name: string }; result: Record<string, never> };
  "style.setParam": { params: { styleName: string; paramName: string; value: number }; result: Record<string, never> };
  "scene.spawnActor": { params: { kind: string }; result: { entityId: number } };
  "renderqueue.listJobs": { params: Record<string, never>; result: { jobs: { index: number; sequencePath: string; outputDir: string; width: number; height: number; format: string; samples: number; bounces: number; usePathTrace: boolean; encodeVideo: boolean; videoCodec: string; status: string; totalFrames: number; currentFrame: number; statusMessage: string }[]; isRunning: boolean } };
  "renderqueue.addJob": { params: { sequencePath: string; outputDir?: string; width?: number; height?: number; format?: string; samples?: number; bounces?: number; usePathTrace?: boolean; encodeVideo?: boolean; videoCodec?: string }; result: { index: number } };
  "renderqueue.removeJob": { params: { index: number }; result: Record<string, never> };
  "renderqueue.startQueue": { params: Record<string, never>; result: Record<string, never> };
  "renderqueue.cancelQueue": { params: Record<string, never>; result: Record<string, never> };
  "renderqueue.clearCompleted": { params: Record<string, never>; result: Record<string, never> };
  "physicsviz.getSettings": { params: Record<string, never>; result: { drawMode: string; opacity: number; velocityScale: number; wireframeOnly: boolean; showCollisionShapes: boolean; showRigidbodies: boolean; showTriggers: boolean; showConstraints: boolean; showVelocityVectors: boolean; showSleepState: boolean; showAabbs: boolean; colorStatic: unknown /* [4]f32 */; colorDynamic: unknown /* [4]f32 */; colorKinematic: unknown /* [4]f32 */; colorTrigger: unknown /* [4]f32 */; colorSleeping: unknown /* [4]f32 */; colorConstraint: unknown /* [4]f32 */ } };
  "physicsviz.setDrawMode": { params: { mode: string }; result: Record<string, never> };
  "physicsviz.setToggle": { params: { key: string; value: boolean }; result: Record<string, never> };
  "physicsviz.setFloat": { params: { key: string; value: number }; result: Record<string, never> };
  "physicsviz.setColor": { params: { key: string; r: number; g: number; b: number; a: number }; result: Record<string, never> };
  "utilities.list": { params: Record<string, never>; result: { utilities: { handle: number; name: string; description: string; sourcePath: string; status: string; open: boolean; lastError: string }[] } };
  "utilities.setOpen": { params: { handle: number; open: boolean }; result: Record<string, never> };
  "utilities.remove": { params: { handle: number }; result: Record<string, never> };
  "rendersettings.getSettings": { params: Record<string, never>; result: { shadingMode: string; transformSpace: string; showGrid: boolean; showBones: boolean; showCollision: boolean; pathTrace: { samples: number; bounces: number; resolutionScale: number }; viewportSize: { width: number; height: number }; renderOutput: { preset: string; width: number; height: number; format: string; path: string } } };
  "rendersettings.setShadingMode": { params: { mode: string }; result: Record<string, never> };
  "rendersettings.setTransformSpace": { params: { space: string }; result: Record<string, never> };
  "rendersettings.setOverlay": { params: { key: string; value: boolean }; result: Record<string, never> };
  "rendersettings.setPathTrace": { params: { samples?: number; bounces?: number; resolutionScale?: number }; result: Record<string, never> };
  "rendersettings.applyPtPreset": { params: { preset: string }; result: Record<string, never> };
  "rendersettings.setRenderOutput": { params: { preset?: string; width?: number; height?: number; format?: string; path?: string }; result: Record<string, never> };
}

// ── Subscription Events ───────────────────────────────────

export interface SubscriptionEvents {
  "on:scene.changed": { revision: number; entityIds: number[] };
  "on:selection.changed": { entityIds: number[] };
  "on:console.log": LogEntry;
  "on:viewport.metrics": { fps: number; drawCalls: number; triangles: number };
  "on:playback.stateChanged": { state: string };
  "on:asset.changed": { assetId: string; changeType: string };
  "on:editor.historyChanged": { cursor: number; totalEntries: number };
}

// ── Convenience Aliases ───────────────────────────────────

export type RpcMethodName = keyof RpcMethods;
export type SubscriptionName = keyof SubscriptionEvents;

export type RpcParams<M extends RpcMethodName> = RpcMethods[M]["params"];
export type RpcResult<M extends RpcMethodName> = RpcMethods[M]["result"];

// ── JSON-RPC 2.0 Wire Format ─────────────────────────────

export interface JsonRpcRequest {
  jsonrpc: "2.0";
  id: number | string;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: number | string;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}
