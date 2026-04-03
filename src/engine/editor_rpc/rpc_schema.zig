///! RPC contract schema — THE single source of truth.
///!
///! This file defines every RPC method, shared data type, and subscription
///! event in a fully declarative way. It has ZERO project imports, making
///! it usable by both the engine (runtime dispatch) and the codegen tool
///! (comptime → TypeScript).
///!
///! Workflow:
///!   1. Edit this file to add/change methods or types.
///!   2. Run:  zig run tools/gen_rpc_types.zig > editor-electron/src/shared/rpc-types.generated.ts
///!   3. Both Zig and TypeScript are now in sync.

// ═══════════════════════════════════════════════════════════════════
//  Shared data types
// ═══════════════════════════════════════════════════════════════════

pub const SharedTypes = struct {
    pub const Vec3 = struct {
        x: f32,
        y: f32,
        z: f32,
    };

    pub const Quat = struct {
        x: f32,
        y: f32,
        z: f32,
        w: f32,
    };

    pub const Transform = struct {
        position: Vec3,
        rotation: Quat,
        scale: Vec3,
    };

    pub const TransformPartial = struct {
        position: ?Vec3 = null,
        rotation: ?Quat = null,
        scale: ?Vec3 = null,
    };

    pub const EntityNode = struct {
        id: u64,
        name: []const u8,
        visible: bool,
        children: []const EntityNode,
    };

    pub const ComponentInfo = struct {
        type: []const u8,
        fields: []const ComponentField,
    };

    pub const ComponentField = struct {
        name: []const u8,
        fieldType: []const u8,
        value: JsonValue,
        options: ?[]const []const u8 = null,
    };

    /// Opaque JSON value — codegen emits this as `unknown`.
    pub const JsonValue = struct { _opaque: u8 = 0 };

    pub const LogEntry = struct {
        level: []const u8,
        message: []const u8,
        timestamp: f64,
        source: ?[]const u8 = null,
    };

    pub const AssetEntry = struct {
        name: []const u8,
        path: []const u8,
        isDirectory: bool,
        assetType: ?[]const u8 = null,
        size: ?u64 = null,
    };
};

// ═══════════════════════════════════════════════════════════════════
//  RPC method contracts — { Params, Result } per method
// ═══════════════════════════════════════════════════════════════════

pub const Methods = struct {
    // ── editor namespace ─────────────────────────────────────────

    pub const @"editor.ping" = struct {
        pub const Params = struct {};
        pub const Result = struct { pong: bool };
    };

    pub const @"editor.getCapabilities" = struct {
        pub const Params = struct {};
        pub const Result = struct {
            version: []const u8,
            methods: []const []const u8,
            subscriptions: []const []const u8,
        };
    };

    pub const @"editor.setSelection" = struct {
        pub const Params = struct { entityIds: []const u64 };
        pub const Result = struct {};
    };

    pub const @"editor.undo" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    pub const @"editor.redo" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    pub const @"editor.getHistory" = struct {
        pub const Params = struct {};
        pub const Result = struct {
            cursor: u64,
            entries: []const HistoryEntry,
        };

        pub const HistoryEntry = struct {
            sequence: u64,
            label: []const u8,
            source: []const u8,
            detail: ?[]const u8 = null,
            timestampMs: i64,
        };
    };

    pub const @"editor.timeTravel" = struct {
        pub const Params = struct { targetSequence: u64 };
        pub const Result = struct {};
    };

    // ── scene namespace ──────────────────────────────────────────

    pub const @"scene.getHierarchy" = struct {
        pub const Params = struct {};
        pub const Result = struct { roots: []const SharedTypes.EntityNode };
    };

    pub const @"scene.createEntity" = struct {
        pub const Params = struct {
            name: ?[]const u8 = null,
            parentId: ?u64 = null,
        };
        pub const Result = struct { entityId: u64 };
    };

    pub const @"scene.deleteEntity" = struct {
        pub const Params = struct { entityId: u64 };
        pub const Result = struct {};
    };

    pub const @"scene.duplicateEntity" = struct {
        pub const Params = struct { entityId: u64 };
        pub const Result = struct { entityId: u64 };
    };

    pub const @"scene.save" = struct {
        pub const Params = struct { path: ?[]const u8 = null };
        pub const Result = struct { path: []const u8 };
    };

    pub const @"scene.load" = struct {
        pub const Params = struct { path: []const u8 };
        pub const Result = struct { path: []const u8 };
    };

    pub const @"scene.listScenes" = struct {
        pub const Params = struct {};
        pub const Result = struct { scenes: []const []const u8 };
    };

    // ── entity namespace ─────────────────────────────────────────

    pub const @"entity.getTransform" = struct {
        pub const Params = struct { entityId: u64 };
        pub const Result = SharedTypes.Transform;
    };

    pub const @"entity.setTransform" = struct {
        pub const Params = struct {
            entityId: u64,
            transform: SharedTypes.TransformPartial,
        };
        pub const Result = struct {};
    };

    pub const @"entity.setName" = struct {
        pub const Params = struct {
            entityId: u64,
            name: []const u8,
        };
        pub const Result = struct {};
    };

    pub const @"entity.getComponents" = struct {
        pub const Params = struct { entityId: u64 };
        pub const Result = struct { components: []const SharedTypes.ComponentInfo };
    };

    pub const @"entity.setComponentField" = struct {
        pub const Params = struct {
            entityId: u64,
            componentType: []const u8,
            fieldName: []const u8,
            value: SharedTypes.JsonValue,
        };
        pub const Result = struct {};
    };

    pub const @"entity.addComponent" = struct {
        pub const Params = struct {
            entityId: u64,
            componentType: []const u8,
        };
        pub const Result = struct {};
    };

    pub const @"entity.removeComponent" = struct {
        pub const Params = struct {
            entityId: u64,
            componentType: []const u8,
        };
        pub const Result = struct {};
    };

    // ── playback namespace ───────────────────────────────────────

    pub const @"playback.play" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    pub const @"playback.pause" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    pub const @"playback.stop" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    // ── viewport namespace ───────────────────────────────────────

    pub const @"viewport.setGizmoMode" = struct {
        pub const Params = struct { mode: []const u8 };
        pub const Result = struct {};
    };

    pub const @"viewport.setRect" = struct {
        pub const Params = struct {
            x: i64,
            y: i64,
            width: i64,
            height: i64,
        };
        pub const Result = struct {};
    };

    pub const @"viewport.getWindowInfo" = struct {
        pub const Params = struct {};
        pub const Result = struct {
            x: i32,
            y: i32,
            width: u32,
            height: u32,
            drawableWidth: u32,
            drawableHeight: u32,
            nativeHandle: u64,
            platform: []const u8,
        };
    };

    pub const @"viewport.attachToParent" = struct {
        pub const Params = struct { parentHandle: u64 };
        pub const Result = struct {};
    };

    pub const @"viewport.detachFromParent" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    pub const @"viewport.getSurfaceId" = struct {
        pub const Params = struct {};
        pub const Result = struct {
            surfaceId: u32,
            width: u32,
            height: u32,
        };
    };

    pub const @"viewport.getRenderSettings" = struct {
        pub const Params = struct {};
        pub const Result = struct {
            shadingMode: []const u8,
            showGrid: bool,
            showBones: bool,
            showCollision: bool,
            bloomEnabled: bool,
            bloomThreshold: f32,
            bloomIntensity: f32,
            exposureEnabled: bool,
            exposure: f32,
            ssaoEnabled: bool,
            ssaoRadius: f32,
            ssaoIntensity: f32,
            fxaaEnabled: bool,
            taaEnabled: bool,
            contactShadowsEnabled: bool,
            colorGradingEnabled: bool,
            colorGradingSaturation: f32,
            colorGradingContrast: f32,
            colorGradingGamma: f32,
            dofEnabled: bool,
            dofFocusDistance: f32,
            dofFocusRange: f32,
        };
    };

    pub const @"viewport.setRenderSettings" = struct {
        pub const Params = struct {
            shadingMode: ?[]const u8 = null,
            showGrid: ?bool = null,
            showBones: ?bool = null,
            showCollision: ?bool = null,
            bloomEnabled: ?bool = null,
            bloomThreshold: ?f32 = null,
            bloomIntensity: ?f32 = null,
            exposureEnabled: ?bool = null,
            exposure: ?f32 = null,
            ssaoEnabled: ?bool = null,
            ssaoRadius: ?f32 = null,
            ssaoIntensity: ?f32 = null,
            fxaaEnabled: ?bool = null,
            taaEnabled: ?bool = null,
            contactShadowsEnabled: ?bool = null,
            colorGradingEnabled: ?bool = null,
            colorGradingSaturation: ?f32 = null,
            colorGradingContrast: ?f32 = null,
            colorGradingGamma: ?f32 = null,
            dofEnabled: ?bool = null,
            dofFocusDistance: ?f32 = null,
            dofFocusRange: ?f32 = null,
        };
        pub const Result = struct {};
    };

    // ── console namespace ────────────────────────────────────────

    pub const @"console.clear" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
    };

    // ── assets namespace ─────────────────────────────────────────

    pub const @"assets.list" = struct {
        pub const Params = struct { path: ?[]const u8 = null };
        pub const Result = struct {
            path: []const u8,
            entries: []const SharedTypes.AssetEntry,
        };
    };
};

// ═══════════════════════════════════════════════════════════════════
//  Subscription event payloads
// ═══════════════════════════════════════════════════════════════════

pub const Subscriptions = struct {
    pub const @"on:scene.changed" = struct {
        revision: u64,
        entityIds: []const u64,
    };

    pub const @"on:selection.changed" = struct {
        entityIds: []const u64,
    };

    pub const @"on:console.log" = SharedTypes.LogEntry;

    pub const @"on:viewport.metrics" = struct {
        fps: f64,
        drawCalls: u64,
        triangles: u64,
    };

    pub const @"on:playback.stateChanged" = struct {
        state: []const u8,
    };

    pub const @"on:asset.changed" = struct {
        assetId: []const u8,
        changeType: []const u8,
    };

    pub const @"on:editor.historyChanged" = struct {
        cursor: u64,
        totalEntries: u64,
    };
};
