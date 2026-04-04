import { app, BrowserWindow, ipcMain, session } from "electron";
import path from "path";
import { EngineProcess } from "./engine-process";
import { EngineClient } from "./engine-client";

const DEFAULT_PORT = 9100;

let mainWindow: BrowserWindow | null = null;
let engineProcess: EngineProcess | null = null;
let engineClient: EngineClient | null = null;

// ── Native viewport addon (platform-specific) ───────────────────

interface ViewportAddon {
  attach(handle: Buffer, surfaceId: number, x: number, y: number, w: number, h: number): void;
  updateSurface(surfaceId: number, shmName?: string, width?: number, height?: number): void;
  detach(): void;
  refresh(): { pixels: Buffer; width: number; height: number } | void;
}

let ioSurfaceView: ViewportAddon | null = null;
const isMac = process.platform === "darwin";
try {
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  ioSurfaceView = require(
    path.join(__dirname, "../../native/build/Release/iosurface_view.node"),
  ) as ViewportAddon;
} catch (err) {
  console.warn("[Main] Viewport native addon not available:", err);
}

function getEngineBinaryPath(): string {
  // In development, use the adjacent zig-out build
  const devPath = path.resolve(__dirname, "../../..", "zig-out/bin/guava-engine");
  return devPath;
}

function getProjectPath(): string | undefined {
  // Check command-line arguments for --project-path
  const args = process.argv;
  const idx = args.indexOf("--project-path");
  if (idx !== -1 && idx + 1 < args.length) {
    return args[idx + 1];
  }
  return undefined;
}

async function createMainWindow(): Promise<BrowserWindow> {
  const win = new BrowserWindow({
    width: 1600,
    height: 1000,
    minWidth: 800,
    minHeight: 600,
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 12, y: 12 },
    backgroundColor: "#1e1e2e",
    webPreferences: {
      preload: path.join(__dirname, "../preload/preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  // In development, load from Vite dev server; in production, load built files
  if (process.env.VITE_DEV_SERVER_URL) {
    await win.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    await win.loadFile(path.join(__dirname, "../renderer/index.html"));
  }

  // Open DevTools in development for debugging
  if (process.env.NODE_ENV === "development" || process.env.VITE_DEV_SERVER_URL) {
    win.webContents.openDevTools({ mode: "detach" });
  }

  // Forward renderer console output to main process stdout for debugging
  win.webContents.on("console-message", (_event, level, message, line, sourceId) => {
    const prefix = ["[Renderer:V]", "[Renderer:I]", "[Renderer:W]", "[Renderer:E]"][level] ?? "[Renderer]";
    console.log(`${prefix} ${message} (${sourceId}:${line})`);
  });

  return win;
}

async function startEngine(): Promise<void> {
  const projectPath = getProjectPath();

  engineProcess = new EngineProcess({
    engineBinary: getEngineBinaryPath(),
    projectPath,
    port: DEFAULT_PORT,
  });

  // Wait for engine to be ready
  const readyPromise = new Promise<void>((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("Engine startup timeout")), 15000);

    engineProcess!.once("ready", () => {
      clearTimeout(timeout);
      resolve();
    });

    engineProcess!.once("error", (err: Error) => {
      clearTimeout(timeout);
      reject(err);
    });
  });

  engineProcess.start();
  await readyPromise;

  // Connect WebSocket RPC client
  engineClient = new EngineClient(`ws://127.0.0.1:${DEFAULT_PORT}`, {
    timeout: 10000,
    reconnectInterval: 2000,
  });
  await engineClient.connect();

  // Verify connection
  await engineClient.call("editor.getCapabilities", {});
}

// ── IPC Bridge: Renderer ↔ Engine ────────────────────────────────

ipcMain.handle("engine:call", async (_event, method: string, params: unknown) => {
  if (!engineClient?.connected) {
    throw new Error("Engine not connected");
  }
  // Type narrowing happens at the shared types level in renderer
  return engineClient.call(method as keyof typeof engineClient.call, params as never);
});

ipcMain.handle("engine:status", () => {
  return {
    engineRunning: engineProcess?.running ?? false,
    rpcConnected: engineClient?.connected ?? false,
  };
});

// ── Subscription forwarding: Engine push → Renderer ──────────────

function setupSubscriptionForwarding(): void {
  if (!engineClient || !mainWindow) return;

  const events = [
    "on:scene.changed",
    "on:selection.changed",
    "on:viewport.metrics",
    "on:console.log",
    "on:playback.stateChanged",
    "on:asset.changed",
    "on:editor.historyChanged",
  ] as const;

  for (const event of events) {
    engineClient.on(event, (data) => {
      mainWindow?.webContents.send("engine:event", event, data);
    });
  }
}

// ── Viewport integration (cross-platform) ────────────────────────

let surfaceRefreshTimer: ReturnType<typeof setInterval> | null = null;

// Renderer calls this to start pixel streaming from the engine's shared surface.
ipcMain.handle(
  "viewport:attachSurface",
  async (_event, surfaceId: number, _x: number, _y: number, w: number, h: number, shmName?: string) => {
    if (!ioSurfaceView || !mainWindow) return false;

    if (isMac) {
      // macOS: store the IOSurface reference for pixel readback
      ioSurfaceView.attach(Buffer.alloc(8), surfaceId, 0, 0, w, h);
    } else if (shmName) {
      // Linux: set up shm mapping for pixel readback
      ioSurfaceView.updateSurface(0, shmName, w, h);
    }

    // Both platforms use the same pixel streaming path:
    // refresh() returns { pixels, width, height } which we forward to the renderer.
    if (surfaceRefreshTimer) clearInterval(surfaceRefreshTimer);
    surfaceRefreshTimer = setInterval(() => {
      if (!ioSurfaceView) return;
      const result = ioSurfaceView.refresh();
      if (result && result.pixels) {
        mainWindow?.webContents.send("viewport:pixels", result.pixels, result.width, result.height);
      }
    }, 16);

    return true;
  },
);

ipcMain.handle("viewport:updateSurface", async (_event, surfaceId: number, shmName?: string, width?: number, height?: number) => {
  if (isMac) {
    ioSurfaceView?.updateSurface(surfaceId);
  } else if (shmName && width && height) {
    ioSurfaceView?.updateSurface(0, shmName, width, height);
  }
});

ipcMain.handle("viewport:detach", async () => {
  if (surfaceRefreshTimer) {
    clearInterval(surfaceRefreshTimer);
    surfaceRefreshTimer = null;
  }
  ioSurfaceView?.detach();
});

// ── App Lifecycle ────────────────────────────────────────────────

app.whenReady().then(async () => {
  // Set Content-Security-Policy to suppress Electron security warning.
  // In dev mode Vite injects inline scripts for HMR, so we must allow 'unsafe-inline'.
  const isDev = !!(process.env.VITE_DEV_SERVER_URL);
  const scriptSrc = isDev
    ? "script-src 'self' 'unsafe-inline' http://localhost:*"
    : "script-src 'self'";
  session.defaultSession.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: {
        ...details.responseHeaders,
        "Content-Security-Policy": [
          `default-src 'self'; ${scriptSrc}; style-src 'self' 'unsafe-inline'; connect-src 'self' ws://127.0.0.1:* http://localhost:*; img-src 'self' data:`,
        ],
      },
    });
  });

  mainWindow = await createMainWindow();

  try {
    await startEngine();
    setupSubscriptionForwarding();
    mainWindow.webContents.send("engine:connected");
  } catch (err) {
    console.error("[Main] Failed to start engine:", err);
    mainWindow.webContents.send("engine:error", String(err));
  }

  mainWindow.on("close", () => {
    // Stop the IOSurface refresh timer before the window handle becomes invalid
    if (surfaceRefreshTimer) {
      clearInterval(surfaceRefreshTimer);
      surfaceRefreshTimer = null;
    }
    ioSurfaceView?.detach();
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
});

app.on("window-all-closed", async () => {
  engineClient?.disconnect();
  await engineProcess?.stop();
  app.quit();
});

app.on("before-quit", async () => {
  engineClient?.disconnect();
  await engineProcess?.stop();
});
