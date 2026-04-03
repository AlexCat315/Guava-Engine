import { contextBridge, ipcRenderer } from "electron";

/**
 * Exposes a safe API to the renderer process via context bridge.
 * The renderer process cannot access Node.js or Electron APIs directly.
 */
contextBridge.exposeInMainWorld("guavaEngine", {
  /** Call an engine RPC method */
  call: (method: string, params: unknown): Promise<unknown> =>
    ipcRenderer.invoke("engine:call", method, params),

  /** Get engine connection status */
  getStatus: (): Promise<{ engineRunning: boolean; rpcConnected: boolean }> =>
    ipcRenderer.invoke("engine:status"),

  /** Subscribe to engine push events */
  onEvent: (
    callback: (event: string, data: unknown) => void,
  ): (() => void) => {
    const handler = (
      _event: Electron.IpcRendererEvent,
      eventName: string,
      data: unknown,
    ) => {
      callback(eventName, data);
    };
    ipcRenderer.on("engine:event", handler);
    return () => ipcRenderer.removeListener("engine:event", handler);
  },

  /** Engine connected notification */
  onConnected: (callback: () => void): (() => void) => {
    const handler = () => callback();
    ipcRenderer.on("engine:connected", handler);
    return () => ipcRenderer.removeListener("engine:connected", handler);
  },

  /** Engine error notification */
  onError: (callback: (error: string) => void): (() => void) => {
    const handler = (_event: Electron.IpcRendererEvent, error: string) =>
      callback(error);
    ipcRenderer.on("engine:error", handler);
    return () => ipcRenderer.removeListener("engine:error", handler);
  },

  // ── IOSurface viewport (macOS) ─────────────────────────────────

  /** Attach an IOSurface layer to the Electron window at the given rect */
  viewportAttachSurface: (
    surfaceId: number,
    x: number,
    y: number,
    w: number,
    h: number,
  ): Promise<boolean> =>
    ipcRenderer.invoke("viewport:attachSurface", surfaceId, x, y, w, h),

  /** Update the IOSurface layer's position/size */
  viewportUpdateFrame: (x: number, y: number, w: number, h: number): Promise<void> =>
    ipcRenderer.invoke("viewport:updateFrame", x, y, w, h),

  /** Replace the IOSurface (e.g. after engine-side resize) */
  viewportUpdateSurface: (surfaceId: number): Promise<void> =>
    ipcRenderer.invoke("viewport:updateSurface", surfaceId),

  /** Remove the IOSurface layer */
  viewportDetach: (): Promise<void> => ipcRenderer.invoke("viewport:detach"),
});

/** Type declaration for the exposed API (used in renderer) */
export interface GuavaEngineAPI {
  call<M extends import("../shared/rpc-types").RpcMethodName>(
    method: M,
    params: import("../shared/rpc-types").RpcParams<M>,
  ): Promise<import("../shared/rpc-types").RpcResult<M>>;
  getStatus(): Promise<{ engineRunning: boolean; rpcConnected: boolean }>;
  onEvent(callback: (event: string, data: unknown) => void): () => void;
  onConnected(callback: () => void): () => void;
  onError(callback: (error: string) => void): () => void;
  viewportAttachSurface(surfaceId: number, x: number, y: number, w: number, h: number): Promise<boolean>;
  viewportUpdateFrame(x: number, y: number, w: number, h: number): Promise<void>;
  viewportUpdateSurface(surfaceId: number): Promise<void>;
  viewportDetach(): Promise<void>;
}
