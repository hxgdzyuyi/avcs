import { useEffect, useMemo, useRef, useState } from "react";
import {
  AlignCenterHorizontal,
  AlignCenterVertical,
  AlignEndHorizontal,
  AlignEndVertical,
  AlignStartHorizontal,
  AlignStartVertical,
  Copy,
  FolderOpen,
  Hand,
  Image,
  Maximize2,
  Minimize2,
  MousePointer2,
  PanelLeftClose,
  PanelLeftOpen,
  Paperclip,
  RotateCcw,
  ZoomIn,
  ZoomOut,
} from "lucide-react";
import IconButton from "../../components/IconButton.jsx";
import { previewUrl } from "../../api.js";
import ImagePreviewDialog from "./ImagePreviewDialog.jsx";

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

const BOARD_TABS = [
  ["output", "Output"],
  ["work", "Work"],
];

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
  onToggleLeftAndMiddle,
}) {
  const viewportRef = useRef(null);
  const cameraRef = useRef(DEFAULT_CAMERA);
  const cameraFrameRef = useRef(null);
  const gestureRef = useRef(null);
  const lastGestureAtRef = useRef(0);
  const [camera, setCamera] = useState(DEFAULT_CAMERA);
  const [isPanning, setIsPanning] = useState(false);
  const [activeTab, setActiveTab] = useState("output");
  const [toolMode, setToolMode] = useState("select");
  const [primarySelectedId, setPrimarySelectedId] = useState(null);
  const [marquee, setMarquee] = useState(null);
  const [layoutMenu, setLayoutMenu] = useState(null);
  const [previewDialog, setPreviewDialog] = useState(null);
  const visibleItems = boardItems;
  const workAssets = useMemo(() => assets.filter((asset) => isWorkAsset(asset)), [assets]);
  const selectedItems = visibleItems.filter((item) => selectedIds.includes(item.id));
  const selectedItem = selectedItems[0] || null;
  const primarySelectedItem = selectedItems.find((item) => item.id === primarySelectedId) || selectedItem;
  const selectedAsset = selectedItem ? assets.find((asset) => asset.id === selectedItem.asset_id) : null;
  const previewAsset = previewDialog ? assets.find((asset) => asset.id === previewDialog.assetId) : null;
  const selectionBounds = useMemo(() => getItemsBounds(selectedItems), [selectedItems]);
  const zoomPercent = Math.round(camera.zoom * 100);
  const referenceSelectedLabel = selectedItems.length > 1 ? `Reference ${selectedItems.length} selected images` : "Reference selected image";
  const activeCount = activeTab === "work" ? workAssets.length : visibleItems.length;

  useEffect(() => {
    cameraRef.current = camera;
  }, [camera]);

  useEffect(() => {
    updateCamera(DEFAULT_CAMERA);
    setPrimarySelectedId(null);
    setMarquee(null);
    setLayoutMenu(null);
    setPreviewDialog(null);
  }, [projectId]);

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
      if (!["Delete", "Backspace"].includes(event.key) || event.repeat) return;
      if (selectedItems.length === 0 || isEditableTarget(event.target)) return;

      event.preventDefault();
      onDeleteSelected({ item: selectedItem, selectedCount: selectedItems.length });
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onDeleteSelected, selectedItem, selectedItems.length]);

  useEffect(() => {
    if (!focusRequest?.assetId) return;
    const item = visibleItems.find((candidate) => candidate.asset_id === focusRequest.assetId);
    if (!item) return;

    centerItem(item);
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
      setIsPanning(false);

      if (!start.moved && pointerEvent.type === "pointerup") setSelectedIds([]);
    }

    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  function startCanvasPointer(event) {
    if (toolMode === "pan") {
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

  async function sendPreviewPrompt() {
    if (!previewDialog || previewDialog.isSending) return;

    const text = previewDialog.prompt.trim();
    if (!text) return;

    setPreviewDialog((current) => (current ? { ...current, isSending: true } : current));

    try {
      await onSendImagePrompt(previewDialog.assetId, text);
      closePreviewDialog();
    } catch {
      setPreviewDialog((current) => (current ? { ...current, isSending: false } : current));
    }
  }

  function startObjectDrag(item, event) {
    if (event.button !== 0) return;

    event.preventDefault();
    event.stopPropagation();

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

    const startItems = visibleItems
      .filter((candidate) => movingIds.includes(candidate.id))
      .map((candidate) => ({
        id: candidate.id,
        x: Number(candidate.x),
        y: Number(candidate.y),
      }));

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

      if (!start.moved) {
        if (!additive && pointerEvent.type === "pointerup") {
          setSelectedIds([item.id]);
          setPrimarySelectedId(item.id);
          openPreviewDialog(item);
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
      onUpdateItems(updates, pointerEvent.type === "pointerup");
    }

    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  function startResize(item, event) {
    event.preventDefault();
    event.stopPropagation();

    const start = {
      x: event.clientX,
      y: event.clientY,
      zoom: cameraRef.current.zoom,
      width: Number(item.display_width),
      height: Number(item.display_height),
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

      const width = Math.max(MIN_OBJECT_SIZE, start.width + (pointerEvent.clientX - start.x) / start.zoom);
      const height = Math.max(MIN_OBJECT_SIZE, start.height + (pointerEvent.clientY - start.y) / start.zoom);
      onResize(item.id, normalizeNumber(width), normalizeNumber(height), true);
    }

    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  function centerItem(item) {
    const rect = viewportRef.current?.getBoundingClientRect();
    if (!rect) return;

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

  function resetCamera() {
    updateCamera(DEFAULT_CAMERA);
  }

  function referenceSelectedItems() {
    selectedItems.forEach((item) => onReferenceAsset(item.asset_id));
  }

  function applyLayout(action) {
    const updates = layoutUpdates(action, selectedItems, primarySelectedItem);
    setLayoutMenu(null);
    if (updates.length > 0) onUpdateItems(updates, true);
  }

  return (
    <section className="board-pane">
      <div className="pane-header">
        <div>
          <span className="eyebrow">Board</span>
          <h2>{activeTab === "work" ? "Work" : "Output"}</h2>
          <span className="board-count">{activeCount} images</span>
        </div>
        <div className="board-controls">
          <IconButton
            className="board-collapse-toggle"
            label={collapsedLeftAndMiddle ? "展开左栏与中栏" : "折叠左栏与中栏"}
            onClick={onToggleLeftAndMiddle}
          >
            {collapsedLeftAndMiddle ? <PanelLeftOpen size={15} /> : <PanelLeftClose size={15} />}
          </IconButton>
          <div className="segmented board-filter" role="tablist" aria-label="Board source">
            {BOARD_TABS.map(([value, label]) => (
              <button
                aria-selected={activeTab === value}
                className={activeTab === value ? "active" : ""}
                role="tab"
                type="button"
                key={value}
                onClick={() => setActiveTab(value)}
              >
                {label}
              </button>
            ))}
          </div>
        </div>
      </div>

      {activeTab === "work" ? (
        <WorkAssetList
          assets={workAssets}
          onReferenceAsset={onReferenceAsset}
          onReveal={onReveal}
          onCopyPath={onCopyPath}
        />
      ) : (
        <>
          <div
            className={`board-shell ${isPanning ? "panning" : ""} ${toolMode === "select" ? "selecting" : "pan-tool"}`}
            ref={viewportRef}
          >
            <div
              className="board-canvas"
              onPointerDown={startCanvasPointer}
            >
              <div
                className="board-world"
                style={{
                  transform: `matrix(${camera.zoom}, 0, 0, ${camera.zoom}, ${-camera.x * camera.zoom}, ${-camera.y * camera.zoom})`,
                }}
              >
                {visibleItems.map((item) => {
                  const asset = assets.find((candidate) => candidate.id === item.asset_id) || { ...item, id: item.asset_id };
                  const selected = selectedIds.includes(item.id);

                  return (
                    <BoardObject
                      key={item.id}
                      item={item}
                      asset={asset}
                      selected={selected}
                      onDragStart={(event) => startObjectDrag(item, event)}
                    />
                  );
                })}
              </div>

              <div className="board-overlay">
                <div className="board-group-title">Output</div>
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
                    />
                  );
                })}
                {selectionBounds && selectedItems.length > 1 ? (
                  <SelectionBounds
                    bounds={selectionBounds}
                    camera={camera}
                    selectedCount={selectedItems.length}
                  />
                ) : null}
                {marquee ? <div className="board-marquee" style={rectStyle(marquee)} /> : null}
                {selectionBounds && selectedItems.length > 1 ? (
                  <LayoutToolbar
                    bounds={selectionBounds}
                    camera={camera}
                    viewportRef={viewportRef}
                    layoutMenu={layoutMenu}
                    setLayoutMenu={setLayoutMenu}
                    onApply={applyLayout}
                    canTidy={selectedItems.length >= 2}
                  />
                ) : null}
              </div>

              {visibleItems.length === 0 ? (
                <div className="empty-board">
                  <Image size={36} />
                  <span>Output images appear here after generation or output scan.</span>
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
            />
          ) : null}

          <div className="board-floating-tools" aria-label="Board tools">
            <div className="board-tool-group">
              <IconButton
                label="Select mode"
                className={toolMode === "select" ? "active" : ""}
                onClick={() => setToolMode("select")}
              >
                <MousePointer2 size={15} />
              </IconButton>
              <IconButton
                label="Pan mode"
                className={toolMode === "pan" ? "active" : ""}
                onClick={() => setToolMode("pan")}
              >
                <Hand size={15} />
              </IconButton>
              <IconButton label={referenceSelectedLabel} onClick={referenceSelectedItems} disabled={selectedItems.length === 0}>
                <Paperclip size={15} />
              </IconButton>
              <IconButton label="Open containing folder" onClick={() => selectedItem && onReveal(selectedItem.asset_id)} disabled={!selectedItem}>
                <FolderOpen size={15} />
              </IconButton>
              <IconButton label={`Copy path${selectedAsset?.file_name ? ` for ${selectedAsset.file_name}` : ""}`} onClick={() => selectedItem && onCopyPath(selectedItem.asset_id)} disabled={!selectedItem}>
                <Copy size={15} />
              </IconButton>
            </div>
            <div className="board-tool-divider" />
            <div className="board-tool-group">
              <IconButton label="Zoom in" onClick={() => zoomAtViewportCenter(BUTTON_ZOOM_FACTOR)} disabled={camera.zoom >= MAX_ZOOM}>
                <ZoomIn size={15} />
              </IconButton>
              <IconButton label="Zoom out" onClick={() => zoomAtViewportCenter(1 / BUTTON_ZOOM_FACTOR)} disabled={camera.zoom <= MIN_ZOOM}>
                <ZoomOut size={15} />
              </IconButton>
              <IconButton label="Reset zoom" onClick={resetCamera}>
                <RotateCcw size={15} />
              </IconButton>
              <IconButton label="Fit selected" onClick={() => fitItems(selectedItems)} disabled={selectedItems.length === 0}>
                <Minimize2 size={15} />
              </IconButton>
              <IconButton label="Fit all" onClick={() => fitItems(visibleItems)} disabled={visibleItems.length === 0}>
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

function WorkAssetList({ assets, onReferenceAsset, onReveal, onCopyPath }) {
  return (
    <div className="work-assets">
      {assets.length === 0 ? (
        <div className="empty-work-assets">
          <Image size={34} />
          <span>Work images appear here after import, upload, paste, or scan.</span>
        </div>
      ) : (
        <div className="work-asset-list" role="list" aria-label="Work images">
          {assets.map((asset) => (
            <div className="work-asset-row" role="listitem" key={asset.id}>
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
                <IconButton label={`Reference ${asset.file_name}`} onClick={() => onReferenceAsset(asset.id)}>
                  <Paperclip size={15} />
                </IconButton>
                <IconButton label={`Open containing folder for ${asset.file_name}`} onClick={() => onReveal(asset.id)}>
                  <FolderOpen size={15} />
                </IconButton>
                <IconButton label={`Copy path for ${asset.file_name}`} onClick={() => onCopyPath(asset.id)}>
                  <Copy size={15} />
                </IconButton>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

function BoardObject({ item, asset, selected, onDragStart }) {
  const style = {
    transform: `translate(${item.x}px, ${item.y}px)`,
    width: `${item.display_width}px`,
    height: `${item.display_height}px`,
    zIndex: item.z_index,
  };

  return (
    <div
      className={`board-object ${selected ? "selected" : ""}`}
      id={`board-item-${item.id}`}
      data-asset-id={item.asset_id}
      style={style}
      onPointerDown={onDragStart}
      tabIndex={selected ? 0 : -1}
    >
      <img alt={asset.file_name} src={previewUrl(asset)} draggable="false" />
    </div>
  );
}

function SelectionOverlay({ item, asset, camera, selectedCount, onResizeStart }) {
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
          <button className="resize-handle control-point se" type="button" aria-label="Resize image" onPointerDown={(event) => onResizeStart?.(item, event)} />
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

function SelectionBounds({ bounds, camera, selectedCount }) {
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
      <span>{selectedCount} selected</span>
    </div>
  );
}

function LayoutToolbar({ bounds, camera, viewportRef, layoutMenu, setLayoutMenu, onApply, canTidy }) {
  const position = layoutToolbarPosition(bounds, camera, viewportRef.current);

  return (
    <div
      className="board-layout-toolbar"
      style={{ left: `${position.left}px`, top: `${position.top}px` }}
      onPointerDown={(event) => event.stopPropagation()}
    >
      <ToolbarMenu
        name="align"
        label="Align"
        open={layoutMenu === "align"}
        setLayoutMenu={setLayoutMenu}
        items={[
          ["align-left", "Align Left", <AlignStartVertical size={14} />],
          ["align-center-x", "Horizontal Center", <AlignCenterVertical size={14} />],
          ["align-right", "Align Right", <AlignEndVertical size={14} />],
          ["align-top", "Align Top", <AlignStartHorizontal size={14} />],
          ["align-center-y", "Vertical Center", <AlignCenterHorizontal size={14} />],
          ["align-bottom", "Align Bottom", <AlignEndHorizontal size={14} />],
          ["normalize-width", "Normalize Width"],
          ["normalize-height", "Normalize Height"],
        ]}
        onApply={onApply}
      />
      <ToolbarMenu
        name="tidy"
        label="Tidy"
        open={layoutMenu === "tidy"}
        setLayoutMenu={setLayoutMenu}
        menuClassName="wide"
        items={[
          ["tidy-horizontal", "Tidy Horizontal Space", null, !canTidy],
          ["tidy-vertical", "Tidy Vertical Space", null, !canTidy],
        ]}
        onApply={onApply}
      />
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

function isWorkAsset(asset) {
  return typeof asset?.relative_path === "string" && asset.relative_path.startsWith("work/");
}

function assetDimensions(asset) {
  const width = Number(asset?.width);
  const height = Number(asset?.height);
  if (Number.isFinite(width) && width > 0 && Number.isFinite(height) && height > 0) {
    return `${Math.round(width)} x ${Math.round(height)}`;
  }

  return "Image";
}

function isEditableTarget(target) {
  if (!(target instanceof Element)) return false;

  const tagName = target.tagName.toLowerCase();
  if (["input", "textarea", "select"].includes(tagName)) return true;
  if (target.isContentEditable) return true;

  return Boolean(target.closest("[contenteditable='true'], .cm-editor, .cm-content"));
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
    left: normalizeNumber((Number(item.x) - camera.x) * camera.zoom),
    top: normalizeNumber((Number(item.y) - camera.y) * camera.zoom),
    width: normalizeNumber(Number(item.display_width) * camera.zoom),
    height: normalizeNumber(Number(item.display_height) * camera.zoom),
  };
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

function layoutToolbarPosition(bounds, camera, viewport) {
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
  const left = clamp(screenBounds.left + screenBounds.width / 2 - 130, 12, Math.max(12, viewportWidth - 272));
  const top = Math.max(12, screenBounds.top - 46);
  return { left, top };
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

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}
