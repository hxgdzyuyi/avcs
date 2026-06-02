import { useEffect, useMemo, useRef, useState } from "react";
import { Copy, FolderOpen, Image, Maximize2, Minimize2, MousePointer2, Paperclip, RotateCcw, ZoomIn, ZoomOut } from "lucide-react";
import IconButton from "../../components/IconButton.jsx";
import { previewUrl } from "../../api.js";

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

const FILTERS = [
  ["all", "All images", "All"],
  ["thread", "Current thread", "Thread"],
  ["generated", "Generated", "Generated"],
  ["imported", "Imported", "Imported"],
  ["recent", "Recent", "Recent"],
];

export default function BoardPane({
  boardItems,
  assets,
  selectedIds,
  setSelectedIds,
  filter,
  setFilter,
  currentThreadId,
  onReferenceAsset,
  onMove,
  onResize,
  onReveal,
  onCopyPath,
  onDeleteSelected,
  focusRequest,
  projectId,
}) {
  const viewportRef = useRef(null);
  const cameraRef = useRef(DEFAULT_CAMERA);
  const cameraFrameRef = useRef(null);
  const gestureRef = useRef(null);
  const lastGestureAtRef = useRef(0);
  const [camera, setCamera] = useState(DEFAULT_CAMERA);
  const [isPanning, setIsPanning] = useState(false);
  const visibleItems = useMemo(
    () => boardItems.filter((item) => matchesFilter(item, filter, currentThreadId)),
    [boardItems, currentThreadId, filter],
  );
  const selectedItems = visibleItems.filter((item) => selectedIds.includes(item.id));
  const selectedItem = selectedItems[0] || null;
  const selectedAsset = selectedItem ? assets.find((asset) => asset.id === selectedItem.asset_id) : null;
  const filterLabel = FILTERS.find(([value]) => value === filter)?.[1] || "All images";
  const zoomPercent = Math.round(camera.zoom * 100);
  const referenceSelectedLabel = selectedItems.length > 1 ? `Reference ${selectedItems.length} selected images` : "Reference selected image";

  useEffect(() => {
    cameraRef.current = camera;
  }, [camera]);

  useEffect(() => {
    updateCamera(DEFAULT_CAMERA);
  }, [projectId]);

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

  function selectItem(item, event) {
    const additive = event.shiftKey || event.metaKey || event.ctrlKey;

    setSelectedIds((current) => {
      if (!additive) return [item.id];
      return current.includes(item.id) ? current.filter((id) => id !== item.id) : [...current, item.id];
    });

    if (!additive) onReferenceAsset(item.asset_id);
  }

  function referenceSelectedItems() {
    selectedItems.forEach((item) => onReferenceAsset(item.asset_id));
  }

  return (
    <section className="board-pane">
      <div className="pane-header">
        <div>
          <span className="eyebrow">Board</span>
          <h2>{filterLabel}</h2>
          <span className="board-count">{visibleItems.length} images</span>
        </div>
        <div className="board-controls">
          <div className="segmented board-filter" title="Filter board items">
            {FILTERS.map(([value, _label, shortLabel]) => (
              <button className={filter === value ? "active" : ""} type="button" key={value} onClick={() => setFilter(value)}>
                {shortLabel}
              </button>
            ))}
          </div>
        </div>
      </div>

      <div
        className={`board-shell ${isPanning ? "panning" : ""}`}
        ref={viewportRef}
      >
        <div
          className="board-canvas"
          onPointerDown={startPan}
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
                  zoom={camera.zoom}
                  onSelect={(event) => selectItem(item, event)}
                  onMove={onMove}
                />
              );
            })}
          </div>

          <div className="board-overlay">
            <div className="board-group-title">{filterLabel}</div>
            {selectedItems.map((item) => {
              const asset = assets.find((candidate) => candidate.id === item.asset_id) || { ...item, id: item.asset_id };

              return (
                <SelectionOverlay
                  key={item.id}
                  item={item}
                  asset={asset}
                  camera={camera}
                  selectedCount={selectedItems.length}
                  onResizeStart={startResize}
                />
              );
            })}
          </div>

          {visibleItems.length === 0 ? (
            <div className="empty-board">
              <Image size={36} />
              <span>Images appear here after upload, scan, import, or generation.</span>
            </div>
          ) : null}
        </div>
      </div>

      <div className="board-floating-tools" aria-label="Board tools">
        <div className="board-tool-group">
          <IconButton label="Select mode" className="active">
            <MousePointer2 size={15} />
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
    </section>
  );
}

function BoardObject({ item, asset, selected, zoom, onSelect, onMove }) {
  const style = {
    transform: `translate(${item.x}px, ${item.y}px)`,
    width: `${item.display_width}px`,
    height: `${item.display_height}px`,
    zIndex: item.z_index,
  };

  function startDrag(event) {
    if (event.button !== 0) return;
    event.preventDefault();
    event.stopPropagation();
    onSelect(event);

    const start = { x: event.clientX, y: event.clientY, zoom, itemX: Number(item.x), itemY: Number(item.y) };

    function move(pointerEvent) {
      const x = start.itemX + (pointerEvent.clientX - start.x) / start.zoom;
      const y = start.itemY + (pointerEvent.clientY - start.y) / start.zoom;
      onMove(item.id, normalizeNumber(x), normalizeNumber(y), false);
    }

    function up(pointerEvent) {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      const x = start.itemX + (pointerEvent.clientX - start.x) / start.zoom;
      const y = start.itemY + (pointerEvent.clientY - start.y) / start.zoom;
      onMove(item.id, normalizeNumber(x), normalizeNumber(y), pointerEvent.type === "pointerup");
    }

    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  }

  return (
    <div
      className={`board-object ${selected ? "selected" : ""}`}
      id={`board-${item.asset_id}`}
      style={style}
      onPointerDown={startDrag}
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
      <span className="control-point nw" />
      <span className="control-point ne" />
      <span className="control-point sw" />
      <button className="resize-handle control-point se" type="button" aria-label="Resize image" onPointerDown={(event) => onResizeStart(item, event)} />
      <div className="object-label">
        <strong>{asset.file_name}</strong>
        <span>
          {Math.round(item.display_width)} x {Math.round(item.display_height)}
        </span>
        {selectedCount > 1 ? <span>{selectedCount} selected</span> : null}
      </div>
    </div>
  );
}

function matchesFilter(item, filter, currentThreadId) {
  const source = item.asset_source || item.source;

  if (filter === "thread") return Boolean(currentThreadId && item.thread_id === currentThreadId);
  if (filter === "generated") return source === "generated";
  if (filter === "imported") return source === "import" || source === "upload" || source === "scan";
  if (filter === "recent") return isRecent(item.created_at);

  return true;
}

function isRecent(value) {
  const timestamp = new Date(value).getTime();
  if (Number.isNaN(timestamp)) return false;
  return Date.now() - timestamp <= 24 * 60 * 60 * 1000;
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
  const viewport = event.currentTarget || document.querySelector(".board-shell");
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

function normalizeNumber(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return 0;
  return Math.round((number + Number.EPSILON) * 1000) / 1000;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}
