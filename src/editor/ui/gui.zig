//! Editor UI abstraction layer.
//!
//! All editor code should use this module for UI operations instead of
//! directly referencing the underlying UI framework. This decouples the
//! editor from any specific immediate-mode UI library.
//!
//! To switch the UI backend (e.g. from Dear ImGui to another framework),
//! modify only the `backend` import below and adapt any API differences
//! in the re-export section.

/// The concrete UI backend currently powering the editor.
/// Swap this single import to migrate to a different framework.
const backend = @import("guava").ui.ImGui;

// ── Re-export the complete backend API ──────────────────────────────────

// Types
pub const Error = backend.Error;
pub const WindowControlButton = backend.WindowControlButton;
pub const StyleColor = backend.StyleColor;
pub const Col = backend.Col;
pub const StyleVar = backend.StyleVar;
pub const TreeNodeEntityResult = backend.TreeNodeEntityResult;
pub const ViewCubeFace = backend.ViewCubeFace;
pub const ViewCubeResult = backend.ViewCubeResult;
pub const WindowFlags = backend.WindowFlags;
pub const DrawList = backend.DrawList;

// Lifecycle
pub const init = backend.init;
pub const shutdown = backend.shutdown;
pub const processEvent = backend.processEvent;
pub const newFrame = backend.newFrame;
pub const render = backend.render;
pub const prepare = backend.prepare;

// Dockspace & layout
pub const beginDockspace = backend.beginDockspace;
pub const resetDefaultLayout = backend.resetDefaultLayout;
pub const loadAnimationLayout = backend.loadAnimationLayout;
pub const saveLayout = backend.saveLayout;
pub const saveLayoutToPath = backend.saveLayoutToPath;
pub const loadLayoutFromPath = backend.loadLayoutFromPath;
pub const editorPrefPathAlloc = backend.editorPrefPathAlloc;

// Input queries
pub const wantsCaptureMouse = backend.wantsCaptureMouse;
pub const wantsCaptureKeyboard = backend.wantsCaptureKeyboard;
pub const wantsTextInput = backend.wantsTextInput;
pub const mousePos = backend.mousePos;

// Item rect
pub const getItemRectMin = backend.getItemRectMin;
pub const getItemRectMax = backend.getItemRectMax;

// Color utilities
pub const getColorU32 = backend.getColorU32;
pub const getColorU32Slot = backend.getColorU32Slot;

// Draw list
pub const getWindowDrawList = backend.getWindowDrawList;

// Windows
pub const beginWindow = backend.beginWindow;
pub const beginWindowFlags = backend.beginWindowFlags;
pub const beginWindowOpen = backend.beginWindowOpen;
pub const beginWindowFlagsOpen = backend.beginWindowFlagsOpen;
pub const endWindow = backend.endWindow;

// Menu bar
pub const beginMainMenuBar = backend.beginMainMenuBar;
pub const endMainMenuBar = backend.endMainMenuBar;
pub const beginMenu = backend.beginMenu;
pub const endMenu = backend.endMenu;
pub const menuItem = backend.menuItem;

// Popups
pub const openPopup = backend.openPopup;
pub const beginPopup = backend.beginPopup;
pub const isPopupOpen = backend.isPopupOpen;
pub const beginPopupContextItem = backend.beginPopupContextItem;
pub const beginPopupContextWindow = backend.beginPopupContextWindow;
pub const endPopup = backend.endPopup;

// Combo
pub const beginCombo = backend.beginCombo;
pub const endCombo = backend.endCombo;

// Buttons
pub const button = backend.button;
pub const buttonEx = backend.buttonEx;
pub const imageButton = backend.imageButton;
pub const invisibleButton = backend.invisibleButton;
pub const windowControlButton = backend.windowControlButton;

// Layout primitives
pub const dummy = backend.dummy;
pub const sameLine = backend.sameLine;
pub const sameLineEx = backend.sameLineEx;
pub const separator = backend.separator;
pub const setNextItemWidth = backend.setNextItemWidth;
pub const setNextWindowPos = backend.setNextWindowPos;
pub const setNextWindowSize = backend.setNextWindowSize;
pub const setNextWindowBgAlpha = backend.setNextWindowBgAlpha;
pub const alignTextToFramePadding = backend.alignTextToFramePadding;
pub const indent = backend.indent;
pub const unindent = backend.unindent;

// Style
pub const pushStyleColor = backend.pushStyleColor;
pub const popStyleColor = backend.popStyleColor;
pub const setStyleColor = backend.setStyleColor;
pub const setStyleVarFloat = backend.setStyleVarFloat;
pub const pushStyleVarFloat = backend.pushStyleVarFloat;
pub const pushStyleVarVec2 = backend.pushStyleVarVec2;
pub const popStyleVar = backend.popStyleVar;

// Child windows
pub const beginChild = backend.beginChild;
pub const endChild = backend.endChild;

// Tables
pub const beginTable = backend.beginTable;
pub const endTable = backend.endTable;
pub const tableSetupColumn = backend.tableSetupColumn;
pub const tableHeadersRow = backend.tableHeadersRow;
pub const tableNextRow = backend.tableNextRow;
pub const tableNextColumn = backend.tableNextColumn;

// Selectable / tree
pub const selectable = backend.selectable;
pub const treeNodeEntity = backend.treeNodeEntity;
pub const treePop = backend.treePop;

// Text
pub const text = backend.text;
pub const setTooltip = backend.setTooltip;
pub const textWrapped = backend.textWrapped;
pub const labelText = backend.labelText;

// ID stack
pub const pushIdU64 = backend.pushIdU64;
pub const popId = backend.popId;

// Item queries
pub const isItemClicked = backend.isItemClicked;
pub const isItemActive = backend.isItemActive;
pub const isItemHovered = backend.isItemHovered;
pub const isItemDeactivatedAfterEdit = backend.isItemDeactivatedAfterEdit;

// Input widgets
pub const inputText = backend.inputText;
pub const inputTextWithHint = backend.inputTextWithHint;
pub const dragFloat = backend.dragFloat;
pub const dragFloat3 = backend.dragFloat3;
pub const checkbox = backend.checkbox;
pub const collapsingHeader = backend.collapsingHeader;

// Drag & drop
pub const beginDragDropSourceU64 = backend.beginDragDropSourceU64;
pub const endDragDropSource = backend.endDragDropSource;
pub const dragDropSourceU64 = backend.dragDropSourceU64;
pub const acceptDragDropPayloadU64 = backend.acceptDragDropPayloadU64;

// Window state
pub const isWindowHovered = backend.isWindowHovered;
pub const isWindowFocused = backend.isWindowFocused;
pub const contentRegionAvail = backend.contentRegionAvail;
pub const cursorScreenPos = backend.cursorScreenPos;
pub const setCursorPos = backend.setCursorPos;
pub const setCursorPosY = backend.setCursorPosY;
pub const windowSize = backend.windowSize;
pub const frameHeight = backend.frameHeight;
pub const time = backend.time;
pub const setScrollHereY = backend.setScrollHereY;

// Images & rendering
pub const image = backend.image;
pub const drawViewCube = backend.drawViewCube;

// Extended widgets
pub const MouseButton = backend.MouseButton;
pub const ColorEditFlags = backend.ColorEditFlags;
pub const dragFloat4 = backend.dragFloat4;
pub const dragInt = backend.dragInt;
pub const colorEdit3 = backend.colorEdit3;
pub const colorEdit4 = backend.colorEdit4;
pub const textColored = backend.textColored;
pub const beginGroup = backend.beginGroup;
pub const endGroup = backend.endGroup;
pub const setItemDefaultFocus = backend.setItemDefaultFocus;
pub const setCursorScreenPos = backend.setCursorScreenPos;
pub const isMouseDoubleClicked = backend.isMouseDoubleClicked;
pub const isMouseDragging = backend.isMouseDragging;
pub const mouseDragDelta = backend.mouseDragDelta;
pub const resetMouseDragDelta = backend.resetMouseDragDelta;
pub const getContentRegionAvail = backend.getContentRegionAvail;
