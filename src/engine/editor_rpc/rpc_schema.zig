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

    // ── console namespace ────────────────────────────────────────

    pub const @"console.clear" = struct {
        pub const Params = struct {};
        pub const Result = struct {};
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
};
