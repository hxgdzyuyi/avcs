import { useEffect, useMemo, useRef, useState } from "react";
import {
  AlignCenterHorizontal,
  AlignCenterVertical,
  AlignEndHorizontal,
  AlignEndVertical,
  AlignStartHorizontal,
  AlignStartVertical,
  ArrowDown,
  ArrowUp,
  BringToFront,
  Copy,
  FolderOpen,
  Hand,
  HelpCircle,
  Image,
  LayoutGrid,
  Maximize2,
  Minimize2,
  MousePointer2,
  PanelLeftClose,
  PanelLeftOpen,
  Paperclip,
  Pencil,
  RotateCcw,
  Redo2,
  SendToBack,
  Trash2,
  Undo2,
  ZoomIn,
  ZoomOut,
} from "lucide-react";
import IconButton from "../../components/IconButton.jsx";
import { previewUrl } from "../../api.js";
import ImagePreviewDialog from "./ImagePreviewDialog.jsx";
import {
  shortcutLabel,
  shouldIgnoreGlobalShortcut,
} from "../../keyboard/shortcuts.js";

const MIN_ZOOM = 0.05;
const MAX_ZOOM = 12;
const MIN_OBJECT_SIZE = 64;
const DEFAULT_CAMERA = { x: 0, y: 0, zoom: 1 };
const RECENT_GESTURE_MS = 120;
const WHEEL_ZOOM_SENSITIVITY = 0.0065;
const WHEEL_ZOOM_MIN_FACTOR = 0.82;
const WHEEL_ZOOM_MAX_FACTOR = 1.22;
const WHEEL_DELTA_LINE = 1;
const WHEEL_DELTA_PAGE = 2;
const BUTTON_ZOOM_FACTOR = 1.3;
const TIDY_SPACE = 16;
const PROPORTIONAL_TARGET_LONG_EDGE = 280;
const PROPORTIONAL_MAX_LONG_EDGE = 720;
const PROPORTIONAL_MAX_ROW_WIDTH = 1280;
const PROPORTIONAL_LAYOUT_GAP = 24;
const PROPORTIONAL_LAYOUT_PADDING = 72;
const PROPORTIONAL_MIN_ROW_WIDTH = 320;
const OBJECT_MENU_WIDTH = 184;
const OBJECT_MENU_HEIGHT = 188;

const BOARD_TABS = [
  ["output", "Output"],
  ["work", "Work"],
];
const defaultT = (key, _params = {}, fallback = key) => fallback;

export default function BoardPane({
  boardItems,
  assets,
  selectedIds,
  setSelectedIds,
  onReferenceAsset,
  onResize,
  onUpdateItems,
  onSendImagePrompt,
  onReveal,
  onCopyPath,
  onDeleteSelected,
  focusRequest,
  projectId,
  collapsedLeftAndMiddle,
  onOpenShortcuts,
  onToggleLeftAndMiddle,
  canUndo,
  canRedo,
  undoLabel,
  redoLabel,
  historyBusy,
  onUndo,
  onRedo,
  onConfirm = async () => false,
  t = defaultT,
}) {
  const viewportRef = useRef(null);
  const cameraRef = useRef(DEFAULT_CAMERA);
  const cameraFrameRef = useRef(null);
  const autoFitProjectRef = useRef(null);
  const gestureRef = useRef(null);
  const lastGestureAtRef = useRef(0);
  const interactionRef = useRef(false);
  const [camera, setCamera] = useState(DEFAULT_CAMERA);
  const [isPanning, setIsPanning] = useState(false);
  const [activeTab, setActiveTab] = useState("output");
  const [toolMode, setToolMode] = useState("select");
  const [spacePanActive, setSpacePanActive] = useState(false);
  const [primarySelectedId, setPrimarySelectedId] = useState(null);
  const [marquee, setMarquee] = useState(null);
  const [layoutMenu, setLayoutMenu] = useState(null);
  const [objectMenu, setObjectMenu] = useState(null);
  const [previewDialog, setPreviewDialog] = useState(null);
  const [focusedWorkAsset, setFocusedWorkAsset] = useState(null);
  const visibleItems = boardItems;
  const workAssets = useMemo(() => assets.filter((asset) => isWorkAsset(asset)), [assets]);
  const selectedItems = visibleItems.filter((item) => selectedIds.includes(item.id));
  const selectedItem = selectedItems[0] || null;
  const primarySelectedItem = selectedItems.find((item) => item.id === primarySelectedId) || selectedItem;
  const selectedAsset = selectedItem ? assets.find((asset) => asset.id === selectedItem.asset_id) : null;
  const previewAsset = previewDialog ? assets.find((asset) => asset.id === previewDialog.assetId) : null;
  const selectionBounds = useMemo(() => getItemsBounds(selectedItems), [selectedItems]);
  const objectMenuState = useMemo(
    () => (objectMenu ? layerMenuState(visibleItems, objectMenu.selectedIds) : null),
    [objectMenu, visibleItems],
  );
  const zoomPercent = Math.round(camera.zoom * 100);
  const collapseShortcut = shortcutLabel({ mod: true, key: "\\" });
  const fitAllShortcut = shortcutLabel({ mod: true, key: "0" });
  const undoShortcut = shortcutLabel({ mod: true, key: "z" });
  const redoShortcut = shortcutLabel({ mod: true, shift: true, key: "z" });
  const referenceSelectedLabel =
    selectedItems.length > 1
      ? t("board.reference_selected_count", { count: selectedItems.length })
      : t("board.reference_selected");
  const undoButtonLabel = `${t("board.undo")}${undoLabel ? ` ${undoLabel}` : ""} (${undoShortcut})`;
  const redoButtonLabel = `${t("board.redo")}${redoLabel ? ` ${redoLabel}` : ""} (${redoShortcut})`;
  const activeCount = activeTab === "work" ? workAssets.length : visibleItems.length;
  const effectiveToolMode = spacePanActive ? "pan" : toolMode;

  useEffect(() => {
    cameraRef.current = camera;
  }, [camera]);

  useEffect(() => {
    autoFitProjectRef.current = null;
    updateCamera(DEFAULT_CAMERA);
    setPrimarySelectedId(null);
    setMarquee(null);
    setLayoutMenu(null);
    setObjectMenu(null);
    setPreviewDialog(null);
    setSpacePanActive(false);
  }, [projectId]);

  useEffect(() => {
    if (activeTab !== "output" || !projectId || visibleItems.length === 0) return undefined;
    if (autoFitProjectRef.current === projectId) return undefined;

    const frame = window.requestAnimationFrame(() => {
      const rect = viewportRef.current?.getBoundingClientRect();
      if (!rect || rect.width <= 0 || rect.height <= 0) return;

      autoFitProjectRef.current = projectId;
      fitItems(visibleItems);
    });

    return () => window.cancelAnimationFrame(frame);
  }, [activeTab, projectId, visibleItems]);

  useEffect(() => {
    setObjectMenu(null);
    setSpacePanActive(false);
  }, [activeTab]);

  useEffect(() => {
    if (!previewDialog) return;
    if (activeTab !== "output") {
      setPreviewDialog(null);
      return;
    }

    const assetExists = assets.some((asset) => asset.id === previewDialog.assetId);
    const itemExists = visibleItems.some(
      (item) => item.id === previewDialog.boardItemId && item.asset_id === previewDialog.assetId,
    );

    if (!assetExists || !itemExists) setPreviewDialog(null);
  }, [activeTab, assets, previewDialog, visibleItems]);

  useEffect(() => {
    const visibleIds = new Set(visibleItems.map((item) => item.id));
    setSelectedIds((current) => current.filter((id) => visibleIds.has(id)));
    setPrimarySelectedId((current) => (current && visibleIds.has(current) ? current : null));
  }, [visibleItems, setSelectedIds]);

  useEffect(() => {
    function handleKeyDown(event) {
      if (activeTab !== "output") return;

      if (isSpaceKey(event)) {
        if (event.repeat || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return;
        if (shouldIgnoreGlobalShortcut(event)) return;
        if (interactionRef.current) return;

        event.preventDefault();
        setSpacePanActive(true);
        return;
      }

      if (event.repeat) return;
      if (shouldIgnoreGlobalShortcut(event)) return;
      if (interactionRef.current) return;

      const historyAction = boardHistoryActionFromKey(event);
      if (historyAction) {
        event.preventDefault();
        if (historyBusy) return;
        if (historyAction === "undo" && canUndo) onUndo?.();
        if (historyAction === "redo" && canRedo) onRedo?.();
        return;
      }

      if (["Delete", "Backspace"].includes(event.key)) {
        if (selectedItems.length === 0) return;

        event.preventDefault();
        onDeleteSelected({ item: selectedItem, selectedCount: selectedItems.length });
        return;
      }

      if ((event.ctrlKey || event.metaKey) && !event.altKey && !event.shiftKey) {
        if (event.key === "0") {
          if (visibleItems.length === 0) return;

          event.preventDefault();
          fitItems(visibleItems);
          return;
        }

        if (event.key === "\\") {
          event.preventDefault();
          onToggleLeftAndMiddle?.();
        }

        return;
      }

      if (event.ctrlKey || event.metaKey || event.altKey) return;

      if (!event.shiftKey && event.key.toLowerCase() === "v") {
        event.preventDefault();
        setToolMode("select");
        return;
      }

      if (!event.shiftKey && event.key.toLowerCase() === "h") {
        event.preventDefault();
        setToolMode("pan");
        return;
      }

      if (event.shiftKey && event.key === "2") {
        if (selectedItems.length === 0) return;

        event.preventDefault();
        fitItems(selectedItems);
        return;
      }

      const layerAction = layerActionFromKey(event);
      if (layerAction) {
        if (selectedItems.length === 0) return;

        event.preventDefault();
        applySelectedLayerAction(layerAction);
      }
    }

    function handleKeyUp(event) {
      if (isSpaceKey(event)) setSpacePanActive(false);
    }

    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("keyup", handleKeyUp);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("keyup", handleKeyUp);
    };
  }, [
    activeTab,
    canRedo,
    canUndo,
    historyBusy,
    onDeleteSelected,
    onRedo,
    onToggleLeftAndMiddle,
    onUndo,
    selectedItem,
    selectedItems,
    visibleItems,
  ]);

  useEffect(() => {
    if (!objectMenu) return undefined;

    function handlePointerDown(event) {
      if (event.target instanceof Element && event.target.closest(".board-object-menu")) return;
      setObjectMenu(null);
    }

    function handleKeyDown(event) {
      if (event.key === "Escape") setObjectMenu(null);
    }

    window.addEventListener("pointerdown", handlePointerDown);
    window.addEventListener("keydown", handleKeyDown);

    return () => {
      window.removeEventListener("pointerdown", handlePointerDown);
      window.removeEventListener("keydown", handleKeyDown);
    };
  }, [objectMenu]);

  useEffect(() => {
    const assetIds = focusRequestAssetIds(focusRequest);
    if (assetIds.length === 0) return;

    const assetIdSet = new Set(assetIds);
    const focusedItems = visibleItems.filter((candidate) =>
      assetIdSet.has(candidate.asset_id),
    );
    const item = focusedItems[0] || null;
    const asset =
      assetIds.length === 1
        ? assets.find((candidate) => candidate.id === assetIds[0])
        : null;

    setLayoutMenu(null);
    setObjectMenu(null);
    setPreviewDialog(null);

    if (!item) {
      if (isWorkAsset(asset)) {
        setSelectedIds([]);
        setPrimarySelectedId(null);
        setFocusedWorkAsset({
          assetId: asset.id,
          requestId: focusRequest.requestId,
        });
        setActiveTab("work");
      }
      return;
    }

    setFocusedWorkAsset(null);
    setActiveTab("output");
    setSelectedIds(focusedItems.map((candidate) => candidate.id));
    setPrimarySelectedId(item.id);

    let cancelled = false;
    let frame = null;
    let attempts = 0;

    function scheduleCenter() {
      frame = window.requestAnimationFrame(() => {
        frame = null;
        if (cancelled) return;

        const rect = viewportRef.current?.getBoundingClientRect();
        if (!rect || rect.width <= 0 || rect.height <= 0) {
          if (attempts < 4) {
            attempts += 1;
            scheduleCenter();
          }
          return;
        }

        if (
          focusRequest.mode === "fit_if_outside" &&
          itemsInViewport(focusedItems, cameraRef.current, viewportRef.current)
        ) {
          return;
        }

        if (focusedItems.length === 1) {
          centerItem(item);
        } else {
          fitItems(focusedItems);
        }
      });
    }

    scheduleCenter();

    return () => {
      cancelled = true;
      if (frame) window.cancelAnimationFrame(frame);
    };
  }, [focusRequest?.requestId]);

  useEffect(() => {
    const viewport = viewportRef.current;
    if (!viewport) return undefined;

    viewport.addEventListener("wheel", handleWheel, { passive: false });
    viewport.addEventListener("gesturestart", handleGestureStart, { passive: false });
    viewport.addEventListener("gesturechange", handleGestureChange, { passive: false });
    viewport.addEventListener("gestureend", handleGestureEnd, { passive: false });

    return () => {
      viewport.removeEventListener("wheel", handleWheel);
      viewport.removeEventListener("gesturestart", handleGestureStart);
      viewport.removeEventListener("gesturechange", handleGestureChange);
      viewport.removeEventListener("gestureend", handleGestureEnd);
    };
  }, []);

  useEffect(() => {
    return () => {
      if (cameraFrameRef.current) {
        window.cancelAnimationFrame(cameraFrameRef.current);
        cameraFrameRef.current = null;
      }
    };
  }, []);

  function updateCamera(updater) {
    const current = cameraRef.current;
    const next = typeof updater === "function" ? updater(current) : updater;
    const normalizedCamera = {
      x: normalizeNumber(next.x),
      y: normalizeNumber(next.y),
      zoom: clamp(next.zoom, MIN_ZOOM, MAX_ZOOM),
    };

    cameraRef.current = normalizedCamera;

    if (typeof window === "undefined" || typeof window.requestAnimationFrame !== "function") {
      setCamera(normalizedCamera);
      return;
    }

    if (cameraFrameRef.current) return;
    cameraFrameRef.current = window.requestAnimationFrame(() => {
      cameraFrameRef.current = null;
      setCamera(cameraRef.current);
    });
  }

  function zoomAtScreenPoint(screenPoint, nextZoom) {
    updateCamera((current) => {
      const zoom = clamp(nextZoom, MIN_ZOOM, MAX_ZOOM);
      const worldPoint = screenToWorld(screenPoint, current);

      return {
        x: worldPoint.x - screenPoint.x / zoom,
        y: worldPoint.y - screenPoint.y / zoom,
        zoom,
      };
    });
  }

  function zoomAtViewportCenter(factor) {
    const rect = viewportRef.current?.getBoundingClientRect();
    if (!rect) return;

    zoomAtScreenPoint({ x: rect.width / 2, y: rect.height / 2 }, cameraRef.current.zoom * factor);
  }

  function panByScreenDelta(deltaX, deltaY) {
    updateCamera((current) => ({
      x: current.x + deltaX / current.zoom,
      y: current.y + deltaY / current.zoom,
      zoom: current.zoom,
    }));
  }

  function handleWheel(event) {
    if (event.cancelable) event.preventDefault();
    if (gestureRef.current || Date.now() - lastGestureAtRef.current < RECENT_GESTURE_MS) return;

    const delta = wheelDeltaToPixels(event);

    if (!event.ctrlKey && !event.metaKey) {
      panByScreenDelta(delta.x, delta.y);
      return;
    }

    const screenPoint = eventToScreenPoint(event);
    if (!screenPoint) return;
    if (delta.y === 0) return;

    const zoomFactor = clamp(
      Math.exp(-delta.y * WHEEL_ZOOM_SENSITIVITY),
      WHEEL_ZOOM_MIN_FACTOR,
      WHEEL_ZOOM_MAX_FACTOR,
    );
    const nextZoom = cameraRef.current.zoom * zoomFactor;
    zoomAtScreenPoint(screenPoint, nextZoom);
  }

  function handleGestureStart(event) {
    if (event.cancelable) event.preventDefault();
    const screenPoint = eventToScreenPoint(event);
    if (!screenPoint) return;

    lastGestureAtRef.current = Date.now();
    gestureRef.current = {
      screenPoint,
      zoom: cameraRef.current.zoom,
    };
  }

  function handleGestureChange(event) {
    if (event.cancelable) event.preventDefault();

    const screenPoint = eventToScreenPoint(event) || gestureRef.current?.screenPoint;
    if (!screenPoint) return;

    lastGestureAtRef.current = Date.now();
    if (!gestureRef.current) {
      gestureRef.current = {
        screenPoint,
        zoom: cameraRef.current.zoom,
      };
    }

    const scale = getGestureScale(event);
    zoomAtScreenPoint(screenPoint, gestureRef.current.zoom * scale);
  }

  function handleGestureEnd(event) {
    if (event?.cancelable) event.preventDefault();
    lastGestureAtRef.current = Date.now();
    gestureRef.current = null;
  }

  function startPan(event) {
    if (event.button !== 0) return;

    event.preventDefault();
    interactionRef.current = true;
    const start = {
      x: event.clientX,
      y: event.clientY,
      camera: cameraRef.current,
      moved: false,
    };

    setIsPanning(true);

    function move(pointerEvent) {
      const dx = pointerEvent.clientX - start.x;
      const dy = pointerEvent.clientY - start.y;
      if (Math.hypot(dx, dy) > 4) start.moved = true;

      updateCamera({
        x: start.camera.x - dx / start.camera.zoom,
        y: start.camera.y - dy / start.camera.zoom,
        zoom: start.camera.zoom,
      });
    }

    function up(pointerEvent) {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      interactionRef.current = false;
      setIsPanning(false);

      if (!start.moved && pointerEvent.type === "pointerup") setSelectedIds([]);
    }

    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  function startCanvasPointer(event) {
    setObjectMenu(null);

    if (effectiveToolMode === "pan") {
      startPan(event);
      return;
    }

    startMarquee(event);
  }

  function startMarquee(event) {
    if (event.button !== 0) return;

    event.preventDefault();
    const startScreen = eventToScreenPoint(event);
    if (!startScreen) return;
    interactionRef.current = true;

    const additive = event.shiftKey || event.metaKey || event.ctrlKey;
    const startWorld = screenToWorld(startScreen, cameraRef.current);
    const start = {
      screen: startScreen,
      world: startWorld,
      moved: false,
    };

    function move(pointerEvent) {
      const point = eventToScreenPoint(pointerEvent);
      if (!point) return;

      if (Math.hypot(point.x - start.screen.x, point.y - start.screen.y) > 4) {
        start.moved = true;
      }

      setMarquee(screenRectFromPoints(start.screen, point));
    }

    function up(pointerEvent) {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      interactionRef.current = false;

      const endScreen = eventToScreenPoint(pointerEvent) || start.screen;
      const endWorld = screenToWorld(endScreen, cameraRef.current);
      setMarquee(null);

      if (!start.moved) {
        if (!additive && pointerEvent.type === "pointerup") {
          setSelectedIds([]);
          setPrimarySelectedId(null);
        }
        return;
      }

      const worldRect = worldRectFromPoints(start.world, endWorld);
      const hitIds = visibleItems
        .filter((item) => rectsIntersect(worldRect, itemWorldRect(item)))
        .map((item) => item.id);

      setSelectedIds((current) => (additive ? mergeIds(current, hitIds) : hitIds));
      setPrimarySelectedId(hitIds[hitIds.length - 1] || (additive ? primarySelectedId : null));
    }

    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  function openPreviewDialog(item) {
    setPreviewDialog({
      assetId: item.asset_id,
      boardItemId: item.id,
      prompt: "",
      isSending: false,
    });
  }

  function closePreviewDialog() {
    const boardItemId = previewDialog?.boardItemId;
    setPreviewDialog(null);

    if (boardItemId && typeof window !== "undefined") {
      window.requestAnimationFrame(() => {
        document.getElementById(`board-item-${boardItemId}`)?.focus({ preventScroll: true });
      });
    }
  }

  function updatePreviewPrompt(prompt) {
    setPreviewDialog((current) => (current ? { ...current, prompt } : current));
  }

  async function sendPreviewPrompt(maskFile = null) {
    if (!previewDialog || previewDialog.isSending) return;

    const text = previewDialog.prompt.trim();
    if (!text) return;

    setPreviewDialog((current) => (current ? { ...current, isSending: true } : current));

    try {
      await onSendImagePrompt(previewDialog.assetId, text, maskFile);
      closePreviewDialog();
    } catch {
      setPreviewDialog((current) => (current ? { ...current, isSending: false } : current));
    }
  }

  function startObjectDrag(item, event) {
    if (event.button !== 0) return;

    event.preventDefault();
    event.stopPropagation();
    setObjectMenu(null);

    const additive = event.shiftKey || event.metaKey || event.ctrlKey;
    const itemSelected = selectedIds.includes(item.id);
    let movingIds = itemSelected ? selectedIds : [item.id];

    if (additive) {
      const nextIds = itemSelected ? selectedIds.filter((id) => id !== item.id) : [...selectedIds, item.id];
      setSelectedIds(nextIds);
      setPrimarySelectedId(itemSelected ? nextIds[nextIds.length - 1] || null : item.id);
      movingIds = itemSelected ? [] : nextIds;
    } else if (!itemSelected) {
      setSelectedIds([item.id]);
      setPrimarySelectedId(item.id);
    } else {
      setPrimarySelectedId(item.id);
    }

    if (movingIds.length === 0) return;
    interactionRef.current = true;

    const startItems = visibleItems
      .filter((candidate) => movingIds.includes(candidate.id))
      .map(boardItemHistorySnapshot);

    const start = {
      x: event.clientX,
      y: event.clientY,
      zoom: cameraRef.current.zoom,
      items: startItems,
      moved: false,
    };

    function move(pointerEvent) {
      const movedDistance = Math.hypot(pointerEvent.clientX - start.x, pointerEvent.clientY - start.y);
      if (!start.moved && movedDistance <= 4) return;
      start.moved = true;

      const dx = (pointerEvent.clientX - start.x) / start.zoom;
      const dy = (pointerEvent.clientY - start.y) / start.zoom;
      const updates = start.items.map((candidate) => ({
        id: candidate.id,
        x: normalizeNumber(candidate.x + dx),
        y: normalizeNumber(candidate.y + dy),
      }));
      onUpdateItems(updates, false);
    }

    function up(pointerEvent) {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      interactionRef.current = false;

      if (!start.moved) {
        if (!additive && pointerEvent.type === "pointerup") {
          setSelectedIds([item.id]);
          setPrimarySelectedId(item.id);
        }
        return;
      }

      const dx = (pointerEvent.clientX - start.x) / start.zoom;
      const dy = (pointerEvent.clientY - start.y) / start.zoom;
      const updates = start.items.map((candidate) => ({
        id: candidate.id,
        x: normalizeNumber(candidate.x + dx),
        y: normalizeNumber(candidate.y + dy),
      }));
      onUpdateItems(
        updates,
        pointerEvent.type === "pointerup",
        pointerEvent.type === "pointerup"
          ? { historyLabel: "Move", beforeSnapshot: start.items }
          : {},
      );
    }

    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  function startResize(item, event) {
    event.preventDefault();
    event.stopPropagation();
    setObjectMenu(null);
    interactionRef.current = true;

    const start = {
      x: event.clientX,
      y: event.clientY,
      zoom: cameraRef.current.zoom,
      width: Number(item.display_width),
      height: Number(item.display_height),
      beforeSnapshot: [boardItemHistorySnapshot(item)],
    };

    function move(pointerEvent) {
      const width = Math.max(MIN_OBJECT_SIZE, start.width + (pointerEvent.clientX - start.x) / start.zoom);
      const height = Math.max(MIN_OBJECT_SIZE, start.height + (pointerEvent.clientY - start.y) / start.zoom);
      onResize(item.id, normalizeNumber(width), normalizeNumber(height), false);
    }

    function up(pointerEvent) {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      interactionRef.current = false;

      const width = Math.max(MIN_OBJECT_SIZE, start.width + (pointerEvent.clientX - start.x) / start.zoom);
      const height = Math.max(MIN_OBJECT_SIZE, start.height + (pointerEvent.clientY - start.y) / start.zoom);
      onUpdateItems(
        [
          {
            id: item.id,
            display_width: normalizeNumber(width),
            display_height: normalizeNumber(height),
          },
        ],
        pointerEvent.type === "pointerup",
        pointerEvent.type === "pointerup"
          ? { historyLabel: "Resize", beforeSnapshot: start.beforeSnapshot }
          : {},
      );
    }

    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  function centerItem(item) {
    const rect = viewportRef.current?.getBoundingClientRect();
    if (!rect || rect.width <= 0 || rect.height <= 0) return;

    const zoom = cameraRef.current.zoom;
    const itemCenterX = Number(item.x) + Number(item.display_width) / 2;
    const itemCenterY = Number(item.y) + Number(item.display_height) / 2;

    updateCamera({
      x: itemCenterX - rect.width / (2 * zoom),
      y: itemCenterY - rect.height / (2 * zoom),
      zoom,
    });
  }

  function fitItems(items) {
    const rect = viewportRef.current?.getBoundingClientRect();
    const bounds = getItemsBounds(items);
    if (!rect || !bounds) return;

    const padding = 72;
    const availableWidth = Math.max(160, rect.width - padding * 2);
    const availableHeight = Math.max(120, rect.height - padding * 2);
    const zoom = clamp(Math.min(availableWidth / bounds.width, availableHeight / bounds.height), MIN_ZOOM, MAX_ZOOM);

    updateCamera({
      x: bounds.x - (rect.width / zoom - bounds.width) / 2,
      y: bounds.y - (rect.height / zoom - bounds.height) / 2,
      zoom,
    });
  }

  function resizeSelectedToActualSize() {
    const updates = selectedItems.map(actualSizeUpdate).filter(Boolean);
    setLayoutMenu(null);
    setObjectMenu(null);
    if (updates.length > 0) onUpdateItems(updates, true, { historyLabel: "Actual size" });
  }

  async function arrangeAllByActualScale() {
    const updates = proportionalArrangeUpdates(
      visibleItems,
      viewportRef.current?.getBoundingClientRect(),
      cameraRef.current,
    );
    setLayoutMenu(null);
    setObjectMenu(null);
    if (updates.length === 0) return;

    const confirmed = await onConfirm({
      title: t("app.arrange_output"),
      message: t("app.arrange_output_message", { count: visibleItems.length }),
      confirmLabel: t("board.arrange_actual"),
      cancelLabel: t("common.cancel"),
    });
    if (!confirmed) return;

    const nextItems = applyBoardItemUpdates(visibleItems, updates);
    onUpdateItems(updates, true, { historyLabel: "Arrange" });

    window.requestAnimationFrame(() => {
      fitItems(nextItems);
    });
  }

  function resetCamera() {
    updateCamera(DEFAULT_CAMERA);
  }

  function referenceSelectedItems() {
    selectedItems.forEach((item) => onReferenceAsset(item.asset_id));
  }

  function referencePrimarySelectedItem() {
    if (!primarySelectedItem) return;

    setLayoutMenu(null);
    setObjectMenu(null);
    onReferenceAsset(primarySelectedItem.asset_id);
  }

  function applyLayout(action) {
    const updates = layoutUpdates(action, selectedItems, primarySelectedItem);
    setLayoutMenu(null);
    setObjectMenu(null);
    if (updates.length > 0) onUpdateItems(updates, true, { historyLabel: layoutHistoryLabel(action) });
  }

  function openObjectMenu(item, event) {
    event.preventDefault();
    event.stopPropagation();

    const itemSelected = selectedIds.includes(item.id);
    const nextSelectedIds = itemSelected ? selectedIds : [item.id];

    if (!itemSelected) setSelectedIds(nextSelectedIds);
    setPrimarySelectedId(item.id);
    setLayoutMenu(null);

    setObjectMenu({
      itemId: item.id,
      selectedIds: nextSelectedIds,
      ...objectMenuPosition(event, viewportRef.current),
    });
  }

  function applyLayerAction(action) {
    if (!objectMenu) return;

    const updates = layerUpdates(action, visibleItems, objectMenu.selectedIds);
    setObjectMenu(null);
    if (updates.length > 0) onUpdateItems(updates, true, { historyLabel: layerHistoryLabel(action) });
  }

  function deleteFromObjectMenu() {
    if (!objectMenu) return;

    const menuItems = visibleItems.filter((item) => objectMenu.selectedIds.includes(item.id));
    const item = visibleItems.find((candidate) => candidate.id === objectMenu.itemId) || menuItems[0] || null;

    setObjectMenu(null);
    onDeleteSelected({ item, selectedCount: menuItems.length });
  }

  function applySelectedLayerAction(action) {
    const updates = layerUpdates(action, visibleItems, selectedIds);
    setLayoutMenu(null);
    setObjectMenu(null);
    if (updates.length > 0) onUpdateItems(updates, true, { historyLabel: layerHistoryLabel(action) });
  }

  return (
    <section className="board-pane">
      <div className="pane-header">
        <div>
          <span className="eyebrow">{t("common.board")}</span>
          <h2>{activeTab === "work" ? t("common.work") : t("common.output")}</h2>
          <span className="board-count">
            {t("board.image_count", { count: activeCount })}
          </span>
        </div>
        <div className="board-controls">
          <IconButton
            className="board-collapse-toggle"
            label={`${collapsedLeftAndMiddle ? t("board.expand_panes") : t("board.collapse_panes")} (${collapseShortcut})`}
            aria-keyshortcuts={collapseShortcut}
            onClick={onToggleLeftAndMiddle}
          >
            {collapsedLeftAndMiddle ? <PanelLeftOpen size={15} /> : <PanelLeftClose size={15} />}
          </IconButton>
          <IconButton
            className="board-shortcuts-toggle"
            label={`${t("board.shortcuts")} (Shift+?)`}
            aria-keyshortcuts="Shift+?"
            onClick={onOpenShortcuts}
          >
            <HelpCircle size={15} />
          </IconButton>
          <div className="segmented board-filter" role="tablist" aria-label={t("board.source")}>
            {BOARD_TABS.map(([value, label]) => (
              <button
                aria-selected={activeTab === value}
                className={activeTab === value ? "active" : ""}
                role="tab"
                type="button"
                key={value}
                onClick={() => setActiveTab(value)}
              >
                {value === "work" ? t("common.work") : t("common.output", {}, label)}
              </button>
            ))}
          </div>
        </div>
      </div>

      {activeTab === "work" ? (
        <WorkAssetList
          assets={workAssets}
          focusedAssetId={focusedWorkAsset?.assetId}
          focusRequestId={focusedWorkAsset?.requestId}
          onReferenceAsset={onReferenceAsset}
          onReveal={onReveal}
          onCopyPath={onCopyPath}
          t={t}
        />
      ) : (
        <>
          <div
            className={`board-shell ${isPanning ? "panning" : ""} ${effectiveToolMode === "select" ? "selecting" : "pan-tool"}`}
            ref={viewportRef}
          >
            <div
              className="board-canvas"
              onPointerDown={startCanvasPointer}
            >
              <div className="board-world">
                {visibleItems.map((item) => {
                  const asset = assets.find((candidate) => candidate.id === item.asset_id) || { ...item, id: item.asset_id };
                  const selected = selectedIds.includes(item.id);

                  return (
                    <BoardObject
                      key={item.id}
                      item={item}
                      asset={asset}
                      camera={camera}
                      selected={selected}
                      onDragStart={(event) => startObjectDrag(item, event)}
                      onContextMenu={(event) => openObjectMenu(item, event)}
                    />
                  );
                })}
              </div>

              <div className="board-overlay">
                <div className="board-group-title">{t("common.output")}</div>
                {selectedItems.map((item) => {
                  const asset = assets.find((candidate) => candidate.id === item.asset_id) || { ...item, id: item.asset_id };

                  return (
                    <SelectionOverlay
                      key={item.id}
                      item={item}
                      asset={asset}
                      camera={camera}
                      selectedCount={selectedItems.length}
                      onResizeStart={selectedItems.length === 1 ? startResize : null}
                      t={t}
                    />
                  );
                })}
                {selectionBounds && selectedItems.length > 1 ? (
                  <SelectionBounds
                    bounds={selectionBounds}
                    camera={camera}
                    selectedCount={selectedItems.length}
                    t={t}
                  />
                ) : null}
                {marquee ? <div className="board-marquee" style={rectStyle(marquee)} /> : null}
                {selectionBounds ? (
                  <LayoutToolbar
                    bounds={selectionBounds}
                    camera={camera}
                    viewportRef={viewportRef}
                    layoutMenu={layoutMenu}
                    setLayoutMenu={setLayoutMenu}
                    onApply={applyLayout}
                    onEdit={
                      selectedItems.length === 1 && primarySelectedItem
                        ? () => openPreviewDialog(primarySelectedItem)
                        : null
                    }
                    onReference={
                      selectedItems.length === 1 && primarySelectedItem
                        ? referencePrimarySelectedItem
                        : null
                    }
                    canTidy={selectedItems.length >= 2}
                    t={t}
                  />
                ) : null}
                {objectMenu && objectMenuState ? (
                  <ObjectLayerMenu
                    menu={objectMenu}
                    state={objectMenuState}
                    onApply={applyLayerAction}
                    onDelete={deleteFromObjectMenu}
                    t={t}
                  />
                ) : null}
              </div>

              {visibleItems.length === 0 ? (
                <div className="empty-board">
                  <Image size={36} />
                  <span>{t("board.empty_output")}</span>
                </div>
              ) : null}
            </div>
          </div>

          {previewDialog && previewAsset ? (
            <ImagePreviewDialog
              asset={previewAsset}
              prompt={previewDialog.prompt}
              isSending={previewDialog.isSending}
              onPromptChange={updatePreviewPrompt}
              onSend={sendPreviewPrompt}
              onClose={closePreviewDialog}
              onReference={() => onReferenceAsset(previewAsset.id)}
              onReveal={() => onReveal(previewAsset.id)}
              onCopyPath={() => onCopyPath(previewAsset.id)}
              t={t}
            />
          ) : null}

          <div className="board-floating-tools" aria-label={t("board.tools")}>
            <div className="board-tool-group">
              <IconButton
                label={`${t("board.select_mode")} (V)`}
                aria-keyshortcuts="V"
                className={toolMode === "select" ? "active" : ""}
                onClick={() => setToolMode("select")}
              >
                <MousePointer2 size={15} />
              </IconButton>
              <IconButton
                label={`${t("board.pan_mode")} (H)`}
                aria-keyshortcuts="H"
                className={toolMode === "pan" ? "active" : ""}
                onClick={() => setToolMode("pan")}
              >
                <Hand size={15} />
              </IconButton>
              <IconButton label={referenceSelectedLabel} onClick={referenceSelectedItems} disabled={selectedItems.length === 0}>
                <Paperclip size={15} />
              </IconButton>
              <IconButton label={t("board.open_folder")} onClick={() => selectedItem && onReveal(selectedItem.asset_id)} disabled={!selectedItem}>
                <FolderOpen size={15} />
              </IconButton>
              <IconButton
                label={
                  selectedAsset?.file_name
                    ? t("board.copy_path_for", { name: selectedAsset.file_name })
                    : t("board.copy_path")
                }
                onClick={() => selectedItem && onCopyPath(selectedItem.asset_id)}
                disabled={!selectedItem}
              >
                <Copy size={15} />
              </IconButton>
            </div>
            <div className="board-tool-divider" />
            <div className="board-tool-group">
              <IconButton
                label={undoButtonLabel}
                aria-keyshortcuts={undoShortcut}
                onClick={onUndo}
                disabled={!canUndo || historyBusy}
              >
                <Undo2 size={15} />
              </IconButton>
              <IconButton
                label={redoButtonLabel}
                aria-keyshortcuts={redoShortcut}
                onClick={onRedo}
                disabled={!canRedo || historyBusy}
              >
                <Redo2 size={15} />
              </IconButton>
            </div>
            <div className="board-tool-divider" />
            <div className="board-tool-group">
              <IconButton label={t("board.zoom_in")} onClick={() => zoomAtViewportCenter(BUTTON_ZOOM_FACTOR)} disabled={camera.zoom >= MAX_ZOOM}>
                <ZoomIn size={15} />
              </IconButton>
              <IconButton label={t("board.zoom_out")} onClick={() => zoomAtViewportCenter(1 / BUTTON_ZOOM_FACTOR)} disabled={camera.zoom <= MIN_ZOOM}>
                <ZoomOut size={15} />
              </IconButton>
              <IconButton label={t("board.reset_zoom")} onClick={resetCamera}>
                <RotateCcw size={15} />
              </IconButton>
              <IconButton label={t("board.actual_size")} onClick={resizeSelectedToActualSize} disabled={selectedItems.length === 0}>
                <Image size={15} />
              </IconButton>
              <IconButton label={t("board.arrange_actual")} onClick={arrangeAllByActualScale} disabled={visibleItems.length === 0}>
                <LayoutGrid size={15} />
              </IconButton>
              <IconButton label={`${t("board.fit_selected")} (Shift+2)`} aria-keyshortcuts="Shift+2" onClick={() => fitItems(selectedItems)} disabled={selectedItems.length === 0}>
                <Minimize2 size={15} />
              </IconButton>
              <IconButton label={`${t("board.fit_all")} (${fitAllShortcut})`} aria-keyshortcuts={fitAllShortcut} onClick={() => fitItems(visibleItems)} disabled={visibleItems.length === 0}>
                <Maximize2 size={15} />
              </IconButton>
              <span className="board-zoom-readout">{zoomPercent}%</span>
            </div>
          </div>
        </>
      )}
    </section>
  );
}

function WorkAssetList({
  assets,
  focusedAssetId,
  focusRequestId,
  onReferenceAsset,
  onReveal,
  onCopyPath,
  t = defaultT,
}) {
  const focusedRowRef = useRef(null);

  useEffect(() => {
    if (!focusedAssetId) return undefined;

    const frame = window.requestAnimationFrame(() => {
      focusedRowRef.current?.scrollIntoView({
        block: "center",
        behavior: "smooth",
      });
      focusedRowRef.current?.focus({ preventScroll: true });
    });

    return () => window.cancelAnimationFrame(frame);
  }, [focusedAssetId, focusRequestId, assets]);

  return (
    <div className="work-assets">
      {assets.length === 0 ? (
        <div className="empty-work-assets">
          <Image size={34} />
          <span>{t("board.empty_work")}</span>
        </div>
      ) : (
        <div className="work-asset-list" role="list" aria-label={t("board.work_images")}>
          {assets.map((asset) => {
            const focused = focusedAssetId === asset.id;

            return (
              <div
                className={`work-asset-row${focused ? " focused" : ""}`}
                role="listitem"
                key={asset.id}
                ref={focused ? focusedRowRef : null}
                tabIndex={focused ? 0 : -1}
              >
                <button
                  className="work-asset-main"
                  type="button"
                  onClick={() => onReferenceAsset(asset.id)}
                >
                  <span className="work-asset-thumb">
                    <img alt={asset.file_name} src={previewUrl(asset)} draggable="false" />
                  </span>
                  <span className="work-asset-meta">
                    <strong>{asset.file_name}</strong>
                    <span>{asset.relative_path}</span>
                    <small>{assetDimensions(asset)}</small>
                  </span>
                </button>
                <div className="work-asset-actions">
                  <IconButton label={t("board.reference_file", { name: asset.file_name })} onClick={() => onReferenceAsset(asset.id)}>
                    <Paperclip size={15} />
                  </IconButton>
                  <IconButton label={t("board.open_folder_for", { name: asset.file_name })} onClick={() => onReveal(asset.id)}>
                    <FolderOpen size={15} />
                  </IconButton>
                  <IconButton label={t("board.copy_path_for", { name: asset.file_name })} onClick={() => onCopyPath(asset.id)}>
                    <Copy size={15} />
                  </IconButton>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

function BoardObject({ item, asset, camera, selected, onDragStart, onContextMenu }) {
  const bounds = worldBoundsToScreen(item, camera);
  const style = {
    left: `${bounds.left}px`,
    top: `${bounds.top}px`,
    width: `${bounds.width}px`,
    height: `${bounds.height}px`,
    zIndex: item.z_index,
  };

  return (
    <div
      className={`board-object ${selected ? "selected" : ""}`}
      id={`board-item-${item.id}`}
      data-asset-id={item.asset_id}
      style={style}
      onPointerDown={onDragStart}
      onContextMenu={onContextMenu}
      tabIndex={selected ? 0 : -1}
    >
      <img alt={asset.file_name} src={previewUrl(asset)} draggable="false" />
    </div>
  );
}

function actualSizeUpdate(item) {
  const width = Number(item.asset_width);
  const height = Number(item.asset_height);
  if (!Number.isFinite(width) || width <= 0 || !Number.isFinite(height) || height <= 0) return null;

  const scale = Math.max(1, MIN_OBJECT_SIZE / width, MIN_OBJECT_SIZE / height);

  return {
    id: item.id,
    display_width: normalizeNumber(width * scale),
    display_height: normalizeNumber(height * scale),
  };
}

function proportionalArrangeUpdates(items, viewport, camera) {
  if (!items.length) return [];

  const scale = proportionalScale(items);
  const sizes = new Map(
    items.map((item) => [
      item.id,
      proportionalSize(item, scale),
    ]),
  );
  const bounds = getItemsBounds(items);
  const anchor = bounds
    ? { x: bounds.x, y: bounds.y }
    : {
        x: normalizeNumber((camera?.x || 0) + PROPORTIONAL_LAYOUT_PADDING),
        y: normalizeNumber((camera?.y || 0) + PROPORTIONAL_LAYOUT_PADDING),
      };
  const viewportWidth = Number(viewport?.width);
  const maxWorldWidth =
    Number.isFinite(viewportWidth) && viewportWidth > 0
      ? clamp(
          viewportWidth - PROPORTIONAL_LAYOUT_PADDING * 2,
          PROPORTIONAL_MIN_ROW_WIDTH,
          PROPORTIONAL_MAX_ROW_WIDTH,
        )
      : clamp(
          bounds?.width || PROPORTIONAL_MAX_ROW_WIDTH,
          PROPORTIONAL_MIN_ROW_WIDTH,
          PROPORTIONAL_MAX_ROW_WIDTH,
        );

  return layoutRows(items, sizes, anchor, maxWorldWidth).filter((update) => {
    const item = items.find((candidate) => candidate.id === update.id);
    return (
      item &&
      (Number(item.x) !== update.x ||
        Number(item.y) !== update.y ||
        Number(item.display_width) !== update.display_width ||
        Number(item.display_height) !== update.display_height)
    );
  });
}

function proportionalScale(items) {
  const longEdges = items
    .map(actualDimensions)
    .filter(Boolean)
    .map((size) => Math.max(size.width, size.height))
    .sort((a, b) => a - b);

  if (longEdges.length === 0) return 1;

  const middle = Math.floor(longEdges.length / 2);
  const median =
    longEdges.length % 2 === 0
      ? (longEdges[middle - 1] + longEdges[middle]) / 2
      : longEdges[middle];

  if (!Number.isFinite(median) || median <= 0) return 1;
  return PROPORTIONAL_TARGET_LONG_EDGE / median;
}

function proportionalSize(item, scale) {
  const sourceSize = actualDimensions(item) || {
    width: MIN_OBJECT_SIZE,
    height: MIN_OBJECT_SIZE,
  };
  let width = sourceSize.width * scale;
  let height = sourceSize.height * scale;

  const longEdge = Math.max(width, height);
  if (longEdge > PROPORTIONAL_MAX_LONG_EDGE) {
    const clampScale = PROPORTIONAL_MAX_LONG_EDGE / longEdge;
    width *= clampScale;
    height *= clampScale;
  }

  const shortEdge = Math.min(width, height);
  if (shortEdge < MIN_OBJECT_SIZE) {
    const clampScale = MIN_OBJECT_SIZE / shortEdge;
    width *= clampScale;
    height *= clampScale;
  }

  return {
    display_width: normalizeNumber(width),
    display_height: normalizeNumber(height),
  };
}

function actualDimensions(item) {
  const assetWidth = positiveNumber(item.asset_width);
  const assetHeight = positiveNumber(item.asset_height);
  if (assetWidth && assetHeight) return { width: assetWidth, height: assetHeight };

  const displayWidth = positiveNumber(item.display_width);
  const displayHeight = positiveNumber(item.display_height);
  if (displayWidth && displayHeight) return { width: displayWidth, height: displayHeight };

  return null;
}

function layoutRows(items, sizes, anchor, maxWorldWidth) {
  let x = anchor.x;
  let y = anchor.y;
  let rowHeight = 0;

  return items.map((item) => {
    const size = sizes.get(item.id) || {
      display_width: MIN_OBJECT_SIZE,
      display_height: MIN_OBJECT_SIZE,
    };

    if (x > anchor.x && x + size.display_width - anchor.x > maxWorldWidth) {
      x = anchor.x;
      y += rowHeight + PROPORTIONAL_LAYOUT_GAP;
      rowHeight = 0;
    }

    const update = {
      id: item.id,
      x: normalizeNumber(x),
      y: normalizeNumber(y),
      display_width: size.display_width,
      display_height: size.display_height,
    };

    x += size.display_width + PROPORTIONAL_LAYOUT_GAP;
    rowHeight = Math.max(rowHeight, size.display_height);

    return update;
  });
}

function applyBoardItemUpdates(items, updates) {
  const updateById = new Map(updates.map((update) => [update.id, update]));

  return items.map((item) => ({
    ...item,
    ...(updateById.get(item.id) || {}),
  }));
}

function ObjectLayerMenu({ menu, state, onApply, onDelete, t = defaultT }) {
  return (
    <div
      className="board-object-menu"
      role="menu"
      aria-label={t("board.item_actions")}
      style={{ left: `${menu.left}px`, top: `${menu.top}px` }}
      onContextMenu={(event) => event.preventDefault()}
      onPointerDown={(event) => event.stopPropagation()}
    >
      <button
        type="button"
        role="menuitem"
        disabled={!state.canBringForward}
        onClick={() => onApply("bring-forward")}
      >
        <ArrowUp size={14} />
        <span>{t("board.move_up")}</span>
      </button>
      <button
        type="button"
        role="menuitem"
        disabled={!state.canSendBackward}
        onClick={() => onApply("send-backward")}
      >
        <ArrowDown size={14} />
        <span>{t("board.move_down")}</span>
      </button>
      <button
        type="button"
        role="menuitem"
        disabled={!state.canBringForward}
        onClick={() => onApply("bring-to-front")}
      >
        <BringToFront size={14} />
        <span>{t("board.move_to_front")}</span>
      </button>
      <button
        type="button"
        role="menuitem"
        disabled={!state.canSendBackward}
        onClick={() => onApply("send-to-back")}
      >
        <SendToBack size={14} />
        <span>{t("board.move_to_back")}</span>
      </button>
      <button
        className="danger"
        type="button"
        role="menuitem"
        onClick={onDelete}
      >
        <Trash2 size={14} />
        <span>{t("board.delete")}</span>
      </button>
    </div>
  );
}

function SelectionOverlay({ item, asset, camera, selectedCount, onResizeStart, t = defaultT }) {
  const bounds = worldBoundsToScreen(item, camera);
  const style = {
    left: `${bounds.left}px`,
    top: `${bounds.top}px`,
    width: `${bounds.width}px`,
    height: `${bounds.height}px`,
    zIndex: Number(item.z_index || 0) + 1000,
  };

  return (
    <div className="selection-overlay" style={style}>
      <div className="selection-frame" />
      {selectedCount === 1 ? (
        <>
          <span className="control-point nw" />
          <span className="control-point ne" />
          <span className="control-point sw" />
          <button className="resize-handle control-point se" type="button" aria-label={t("board.resize_image")} onPointerDown={(event) => onResizeStart?.(item, event)} />
          <div className="object-label">
            <strong>{asset.file_name}</strong>
            <span>
              {Math.round(item.display_width)} x {Math.round(item.display_height)}
            </span>
          </div>
        </>
      ) : null}
    </div>
  );
}

function SelectionBounds({ bounds, camera, selectedCount, t = defaultT }) {
  const screenBounds = worldBoundsToScreen(
    {
      x: bounds.x,
      y: bounds.y,
      display_width: bounds.width,
      display_height: bounds.height,
    },
    camera,
  );

  return (
    <div className="board-selection-bounds" style={rectStyle(screenBounds)}>
      <span>{t("board.selected_count", { count: selectedCount })}</span>
    </div>
  );
}

function LayoutToolbar({
  bounds,
  camera,
  viewportRef,
  layoutMenu,
  setLayoutMenu,
  onApply,
  onEdit,
  onReference,
  canTidy,
  t = defaultT,
}) {
  const compact = Boolean((onEdit || onReference) && !canTidy);
  const position = layoutToolbarPosition(bounds, camera, viewportRef.current, { compact });

  return (
    <div
      className={`board-layout-toolbar ${compact ? "compact" : ""}`}
      style={{ left: `${position.left}px`, top: `${position.top}px` }}
      onPointerDown={(event) => event.stopPropagation()}
    >
      {onEdit ? (
        <button className="board-layout-trigger edit" type="button" onClick={onEdit}>
          <Pencil size={13} />
          <span>{t("common.edit")}</span>
        </button>
      ) : null}
      {onReference ? (
        <button
          aria-label={t("board.reference_selected")}
          className="board-layout-trigger reference"
          title={t("board.reference_selected")}
          type="button"
          onClick={onReference}
        >
          <Paperclip size={13} />
          <span>{t("board.reference")}</span>
        </button>
      ) : null}
      {canTidy ? (
        <>
          <ToolbarMenu
            name="align"
            label={t("board.align")}
            open={layoutMenu === "align"}
            setLayoutMenu={setLayoutMenu}
            items={[
              ["align-left", t("board.align_left"), <AlignStartVertical size={14} />],
              ["align-center-x", t("board.align_center_x"), <AlignCenterVertical size={14} />],
              ["align-right", t("board.align_right"), <AlignEndVertical size={14} />],
              ["align-top", t("board.align_top"), <AlignStartHorizontal size={14} />],
              ["align-center-y", t("board.align_center_y"), <AlignCenterHorizontal size={14} />],
              ["align-bottom", t("board.align_bottom"), <AlignEndHorizontal size={14} />],
              ["normalize-width", t("board.normalize_width")],
              ["normalize-height", t("board.normalize_height")],
            ]}
            onApply={onApply}
          />
          <ToolbarMenu
            name="tidy"
            label={t("board.tidy")}
            open={layoutMenu === "tidy"}
            setLayoutMenu={setLayoutMenu}
            menuClassName="wide"
            items={[
              ["tidy-horizontal", t("board.tidy_horizontal"), null, !canTidy],
              ["tidy-vertical", t("board.tidy_vertical"), null, !canTidy],
            ]}
            onApply={onApply}
          />
        </>
      ) : null}
    </div>
  );
}

function ToolbarMenu({ name, label, open, setLayoutMenu, items, onApply, menuClassName = "" }) {
  return (
    <div className="board-layout-menu-wrap">
      <button type="button" className="board-layout-trigger" onClick={() => setLayoutMenu(open ? null : name)}>
        {label}
      </button>
      {open ? (
        <div className={`board-layout-menu ${menuClassName}`}>
          {items.map(([action, itemLabel, icon, disabled]) => (
            <button type="button" key={action} disabled={disabled} onClick={() => onApply(action)}>
              <span>{icon}</span>
              <strong>{itemLabel}</strong>
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

function isSpaceKey(event) {
  return event.key === " " || event.key === "Spacebar" || event.code === "Space";
}

function boardHistoryActionFromKey(event) {
  if (event.altKey || !(event.ctrlKey || event.metaKey)) return null;

  const key = String(event.key || "").toLowerCase();
  if (key === "z") return event.shiftKey ? "redo" : "undo";
  if (key === "y" && event.ctrlKey && !event.metaKey && !event.shiftKey) return "redo";
  return null;
}

function layerActionFromKey(event) {
  if (event.ctrlKey || event.metaKey || event.altKey) return null;

  const bracketRight =
    event.code === "BracketRight" || event.key === "]" || event.key === "}";
  const bracketLeft =
    event.code === "BracketLeft" || event.key === "[" || event.key === "{";

  if (bracketRight) return event.shiftKey ? "bring-to-front" : "bring-forward";
  if (bracketLeft) return event.shiftKey ? "send-to-back" : "send-backward";
  return null;
}

function boardItemHistorySnapshot(item) {
  return {
    id: item.id,
    x: normalizeNumber(item.x),
    y: normalizeNumber(item.y),
    display_width: normalizeNumber(item.display_width),
    display_height: normalizeNumber(item.display_height),
    z_index: positiveInteger(item.z_index),
  };
}

function isWorkAsset(asset) {
  return (
    asset?.source !== "mask" &&
    typeof asset?.relative_path === "string" &&
    asset.relative_path.startsWith("work/")
  );
}

function assetDimensions(asset) {
  const width = Number(asset?.width);
  const height = Number(asset?.height);
  if (Number.isFinite(width) && width > 0 && Number.isFinite(height) && height > 0) {
    return `${Math.round(width)} x ${Math.round(height)}`;
  }

  return "Image";
}

function focusRequestAssetIds(focusRequest) {
  const ids = Array.isArray(focusRequest?.assetIds)
    ? focusRequest.assetIds
    : focusRequest?.assetId
      ? [focusRequest.assetId]
      : [];

  return [...new Set(ids.filter((id) => typeof id === "string" && id.trim() !== ""))];
}

function screenToWorld(point, camera) {
  return {
    x: point.x / camera.zoom + camera.x,
    y: point.y / camera.zoom + camera.y,
  };
}

function eventToScreenPoint(event) {
  const currentTarget = event.currentTarget;
  const viewport =
    currentTarget instanceof Element
      ? currentTarget
      : document.querySelector(".board-shell");
  const rect = viewport?.getBoundingClientRect();
  if (!rect) return null;

  const hasClientPoint = Number.isFinite(event.clientX) && Number.isFinite(event.clientY);
  if (!hasClientPoint || (event.clientX === 0 && event.clientY === 0)) {
    return { x: rect.width / 2, y: rect.height / 2 };
  }

  return {
    x: event.clientX - rect.left,
    y: event.clientY - rect.top,
  };
}

function getGestureScale(event) {
  const scale = Number(event.scale);
  if (!Number.isFinite(scale) || scale <= 0) return 1;
  return scale;
}

function wheelDeltaToPixels(event) {
  let unit = 1;
  if (event.deltaMode === WHEEL_DELTA_LINE) unit = 16;
  if (event.deltaMode === WHEEL_DELTA_PAGE) unit = viewportSizeFallback();

  return {
    x: Number(event.deltaX || 0) * unit,
    y: Number(event.deltaY || 0) * unit,
  };
}

function viewportSizeFallback() {
  const viewport = document.querySelector(".board-shell");
  return viewport?.getBoundingClientRect().height || window.innerHeight || 800;
}

function worldBoundsToScreen(item, camera) {
  return {
    left: snapToDevicePixel((Number(item.x) - camera.x) * camera.zoom),
    top: snapToDevicePixel((Number(item.y) - camera.y) * camera.zoom),
    width: snapToDevicePixel(Number(item.display_width) * camera.zoom),
    height: snapToDevicePixel(Number(item.display_height) * camera.zoom),
  };
}

function snapToDevicePixel(value) {
  const ratio =
    typeof window !== "undefined" && Number.isFinite(window.devicePixelRatio) && window.devicePixelRatio > 0
      ? window.devicePixelRatio
      : 1;

  return normalizeNumber(Math.round(normalizeNumber(value) * ratio) / ratio);
}

function getItemsBounds(items) {
  if (!items.length) return null;

  const left = Math.min(...items.map((item) => Number(item.x)));
  const top = Math.min(...items.map((item) => Number(item.y)));
  const right = Math.max(...items.map((item) => Number(item.x) + Number(item.display_width)));
  const bottom = Math.max(...items.map((item) => Number(item.y) + Number(item.display_height)));

  return {
    x: left,
    y: top,
    width: Math.max(1, right - left),
    height: Math.max(1, bottom - top),
  };
}

function itemsInViewport(items, camera, viewport) {
  const rect = viewport?.getBoundingClientRect();
  const bounds = getItemsBounds(items);
  if (!rect || rect.width <= 0 || rect.height <= 0 || !bounds) return false;

  const padding = 16;
  const left = (bounds.x - camera.x) * camera.zoom;
  const top = (bounds.y - camera.y) * camera.zoom;
  const right = left + bounds.width * camera.zoom;
  const bottom = top + bounds.height * camera.zoom;

  return (
    left >= padding &&
    top >= padding &&
    right <= rect.width - padding &&
    bottom <= rect.height - padding
  );
}

function itemWorldRect(item) {
  return {
    left: Number(item.x),
    top: Number(item.y),
    right: Number(item.x) + Number(item.display_width),
    bottom: Number(item.y) + Number(item.display_height),
  };
}

function screenRectFromPoints(start, end) {
  const left = Math.min(start.x, end.x);
  const top = Math.min(start.y, end.y);
  return {
    left,
    top,
    width: Math.abs(end.x - start.x),
    height: Math.abs(end.y - start.y),
  };
}

function worldRectFromPoints(start, end) {
  const left = Math.min(start.x, end.x);
  const top = Math.min(start.y, end.y);
  return {
    left,
    top,
    right: Math.max(start.x, end.x),
    bottom: Math.max(start.y, end.y),
  };
}

function rectsIntersect(a, b) {
  return a.left <= b.right && a.right >= b.left && a.top <= b.bottom && a.bottom >= b.top;
}

function rectStyle(rect) {
  return {
    left: `${rect.left}px`,
    top: `${rect.top}px`,
    width: `${rect.width}px`,
    height: `${rect.height}px`,
  };
}

function mergeIds(current, additions) {
  const merged = [...current];
  additions.forEach((id) => {
    if (!merged.includes(id)) merged.push(id);
  });
  return merged;
}

function layoutToolbarPosition(bounds, camera, viewport, options = {}) {
  const rect = viewport?.getBoundingClientRect();
  const screenBounds = worldBoundsToScreen(
    {
      x: bounds.x,
      y: bounds.y,
      display_width: bounds.width,
      display_height: bounds.height,
    },
    camera,
  );
  const viewportWidth = rect?.width || 800;
  const toolbarWidth = options.compact ? 142 : 272;
  const centerX = screenBounds.left + screenBounds.width / 2;
  if (options.compact) {
    return {
      left: clamp(
        centerX,
        toolbarWidth / 2 + 12,
        Math.max(toolbarWidth / 2 + 12, viewportWidth - toolbarWidth / 2 - 12),
      ),
      top: Math.max(12, screenBounds.top - 46),
    };
  }

  const left = clamp(
    centerX - toolbarWidth / 2,
    12,
    Math.max(12, viewportWidth - toolbarWidth - 12),
  );
  const top = Math.max(12, screenBounds.top - 46);
  return { left, top };
}

function objectMenuPosition(event, viewport) {
  const rect = viewport?.getBoundingClientRect();
  if (!rect) return { left: 12, top: 12 };

  const left = event.clientX - rect.left;
  const top = event.clientY - rect.top;
  const maxLeft = Math.max(8, rect.width - OBJECT_MENU_WIDTH - 8);
  const maxTop = Math.max(8, rect.height - OBJECT_MENU_HEIGHT - 8);

  return {
    left: clamp(left, 8, maxLeft),
    top: clamp(top, 8, maxTop),
  };
}

function layerMenuState(items, selectedIds) {
  const order = layerOrderedItems(items);
  const selectedSet = new Set(selectedIds);
  const hasSelection = order.some((item) => selectedSet.has(item.id));

  return {
    canBringForward:
      hasSelection &&
      order.some((item, index) => selectedSet.has(item.id) && index < order.length - 1 && !selectedSet.has(order[index + 1].id)),
    canSendBackward:
      hasSelection &&
      order.some((item, index) => selectedSet.has(item.id) && index > 0 && !selectedSet.has(order[index - 1].id)),
  };
}

function layerUpdates(action, items, selectedIds) {
  const selectedSet = new Set(selectedIds);
  const order = layerOrderedItems(items);
  const selectedItems = order.filter((item) => selectedSet.has(item.id));
  if (selectedItems.length === 0) return [];

  let nextOrder = [...order];

  if (action === "bring-forward") {
    for (let index = nextOrder.length - 2; index >= 0; index -= 1) {
      if (selectedSet.has(nextOrder[index].id) && !selectedSet.has(nextOrder[index + 1].id)) {
        [nextOrder[index], nextOrder[index + 1]] = [nextOrder[index + 1], nextOrder[index]];
      }
    }
  } else if (action === "send-backward") {
    for (let index = 1; index < nextOrder.length; index += 1) {
      if (selectedSet.has(nextOrder[index].id) && !selectedSet.has(nextOrder[index - 1].id)) {
        [nextOrder[index - 1], nextOrder[index]] = [nextOrder[index], nextOrder[index - 1]];
      }
    }
  } else if (action === "bring-to-front") {
    nextOrder = order.filter((item) => !selectedSet.has(item.id)).concat(selectedItems);
  } else if (action === "send-to-back") {
    nextOrder = selectedItems.concat(order.filter((item) => !selectedSet.has(item.id)));
  } else {
    return [];
  }

  const itemById = new Map(items.map((item) => [item.id, item]));

  return nextOrder
    .map((item, index) => ({ id: item.id, z_index: index + 1 }))
    .filter((update) => Number(itemById.get(update.id)?.z_index) !== update.z_index);
}

function layerOrderedItems(items) {
  return items
    .map((item, index) => ({
      item,
      index,
      zIndex: Number(item.z_index || 0),
    }))
    .sort((a, b) => a.zIndex - b.zIndex || a.index - b.index)
    .map(({ item }) => item);
}

function layoutHistoryLabel(action) {
  const labels = {
    "align-left": "Align",
    "align-center-x": "Align",
    "align-right": "Align",
    "align-top": "Align",
    "align-center-y": "Align",
    "align-bottom": "Align",
    "normalize-width": "Normalize width",
    "normalize-height": "Normalize height",
    "tidy-horizontal": "Tidy",
    "tidy-vertical": "Tidy",
  };

  return labels[action] || "Layout";
}

function layerHistoryLabel(action) {
  const labels = {
    "bring-forward": "Layer order",
    "send-backward": "Layer order",
    "bring-to-front": "Layer order",
    "send-to-back": "Layer order",
  };

  return labels[action] || "Layer order";
}

function layoutUpdates(action, items, primaryItem) {
  if (items.length < 2) return [];

  const bounds = getItemsBounds(items);
  if (!bounds) return [];

  if (action === "align-left") {
    return items.map((item) => ({ id: item.id, x: normalizeNumber(bounds.x) }));
  }

  if (action === "align-center-x") {
    const center = bounds.x + bounds.width / 2;
    return items.map((item) => ({
      id: item.id,
      x: normalizeNumber(center - Number(item.display_width) / 2),
    }));
  }

  if (action === "align-right") {
    const right = bounds.x + bounds.width;
    return items.map((item) => ({
      id: item.id,
      x: normalizeNumber(right - Number(item.display_width)),
    }));
  }

  if (action === "align-top") {
    return items.map((item) => ({ id: item.id, y: normalizeNumber(bounds.y) }));
  }

  if (action === "align-center-y") {
    const center = bounds.y + bounds.height / 2;
    return items.map((item) => ({
      id: item.id,
      y: normalizeNumber(center - Number(item.display_height) / 2),
    }));
  }

  if (action === "align-bottom") {
    const bottom = bounds.y + bounds.height;
    return items.map((item) => ({
      id: item.id,
      y: normalizeNumber(bottom - Number(item.display_height)),
    }));
  }

  if (action === "normalize-width" && primaryItem) {
    const width = Math.max(MIN_OBJECT_SIZE, Number(primaryItem.display_width));
    return items.map((item) => ({ id: item.id, display_width: normalizeNumber(width) }));
  }

  if (action === "normalize-height" && primaryItem) {
    const height = Math.max(MIN_OBJECT_SIZE, Number(primaryItem.display_height));
    return items.map((item) => ({ id: item.id, display_height: normalizeNumber(height) }));
  }

  if (action === "tidy-horizontal") return tidyUpdates(items, "horizontal");
  if (action === "tidy-vertical") return tidyUpdates(items, "vertical");

  return [];
}

function tidyUpdates(items, axis) {
  if (items.length < 2) return [];

  const horizontal = axis === "horizontal";
  const sorted = [...items].sort((a, b) => {
    const aCenter = Number(horizontal ? a.x : a.y) + Number(horizontal ? a.display_width : a.display_height) / 2;
    const bCenter = Number(horizontal ? b.x : b.y) + Number(horizontal ? b.display_width : b.display_height) / 2;
    return aCenter - bCenter;
  });

  const start = Math.min(...sorted.map((item) => Number(horizontal ? item.x : item.y)));
  let cursor = start;

  return sorted.map((item) => {
    const update = horizontal
      ? { id: item.id, x: normalizeNumber(cursor) }
      : { id: item.id, y: normalizeNumber(cursor) };
    cursor += Number(horizontal ? item.display_width : item.display_height) + TIDY_SPACE;
    return update;
  });
}

function normalizeNumber(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return 0;
  return Math.round((number + Number.EPSILON) * 1000) / 1000;
}

function positiveNumber(value) {
  const number = Number(value);
  if (!Number.isFinite(number) || number <= 0) return null;
  return number;
}

function positiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 1;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}
