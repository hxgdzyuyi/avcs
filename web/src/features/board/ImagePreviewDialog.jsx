import { useEffect, useRef, useState } from "react";
import {
  Brush,
  Copy,
  Eraser,
  FolderOpen,
  Paperclip,
  Send,
  Trash2,
  Undo2,
  X,
} from "lucide-react";
import IconButton from "../../components/IconButton.jsx";
import { useModalDialog } from "../../components/useModalDialog.js";
import PromptEditor from "../chat/PromptEditor.jsx";
import { previewUrl } from "../../api.js";

const defaultT = (key, _params = {}, fallback = key) => fallback;

export default function ImagePreviewDialog({
  asset,
  prompt,
  isSending,
  onPromptChange,
  onSend,
  onClose,
  onReference,
  onReveal,
  onCopyPath,
  t = defaultT,
}) {
  const closeButtonRef = useRef(null);
  const maskCanvasRef = useRef(null);
  const drawingRef = useRef(null);
  const fileName = asset?.file_name || "Image";
  const sendDisabled = isSending || !prompt.trim();
  const [maskMode, setMaskMode] = useState(false);
  const [maskTool, setMaskTool] = useState("brush");
  const [brushSize, setBrushSize] = useState(44);
  const [maskDirty, setMaskDirty] = useState(false);
  const [canUndo, setCanUndo] = useState(false);
  const [imageSize, setImageSize] = useState(() => ({
    width: positiveNumber(asset?.width) || 1,
    height: positiveNumber(asset?.height) || 1,
  }));
  const canvasWidth = positiveNumber(imageSize.width) || 1;
  const canvasHeight = positiveNumber(imageSize.height) || 1;
  const modalDialogRef = useModalDialog({
    onCancel: onClose,
    initialFocusRef: closeButtonRef,
  });

  useEffect(() => {
    drawingRef.current = null;
    if (maskCanvasRef.current) {
      maskCanvasRef.current.__avcsUndoStack = [];
      maskCanvasRef.current
        .getContext("2d")
        ?.clearRect(0, 0, maskCanvasRef.current.width, maskCanvasRef.current.height);
    }
    setMaskMode(false);
    setMaskTool("brush");
    setMaskDirty(false);
    setCanUndo(false);
    setImageSize({
      width: positiveNumber(asset?.width) || 1,
      height: positiveNumber(asset?.height) || 1,
    });
  }, [asset?.id, asset?.width, asset?.height]);

  function closeOnStage(event) {
    if (event.target === event.currentTarget) onClose();
  }

  function handleImageLoad(event) {
    if (positiveNumber(asset?.width) && positiveNumber(asset?.height)) return;

    const nextWidth = event.currentTarget.naturalWidth;
    const nextHeight = event.currentTarget.naturalHeight;
    if (nextWidth > 0 && nextHeight > 0) {
      setImageSize({ width: nextWidth, height: nextHeight });
    }
  }

  async function handleSend() {
    if (sendDisabled) return;
    const maskFile = maskDirty ? await exportMaskFile(maskCanvasRef.current, fileName) : null;
    await onSend(maskFile);
  }

  function startMaskStroke(event) {
    if (!maskMode || isSending || event.button !== 0) return;

    const canvas = maskCanvasRef.current;
    const point = canvasPoint(event, canvas);
    if (!canvas || !point) return;

    event.preventDefault();
    event.stopPropagation();
    saveUndoSnapshot(canvas);
    setCanUndo(true);

    drawingRef.current = {
      last: point,
      size: brushSize,
      tool: maskTool,
      pointerId: event.pointerId,
    };

    canvas.setPointerCapture?.(event.pointerId);
    drawMaskSegment(canvas, point, point, drawingRef.current);
    setMaskDirty(true);
  }

  function moveMaskStroke(event) {
    const canvas = maskCanvasRef.current;
    const stroke = drawingRef.current;
    if (!canvas || !stroke || stroke.pointerId !== event.pointerId) return;

    const point = canvasPoint(event, canvas);
    if (!point) return;

    event.preventDefault();
    event.stopPropagation();
    drawMaskSegment(canvas, stroke.last, point, stroke);
    stroke.last = point;
    setMaskDirty(true);
  }

  function endMaskStroke(event) {
    const canvas = maskCanvasRef.current;
    const stroke = drawingRef.current;
    if (!stroke || stroke.pointerId !== event.pointerId) return;

    event.preventDefault();
    event.stopPropagation();
    canvas?.releasePointerCapture?.(event.pointerId);
    drawingRef.current = null;
  }

  function clearMask() {
    const canvas = maskCanvasRef.current;
    if (!canvas || isSending || !maskDirty) return;

    saveUndoSnapshot(canvas);
    setCanUndo(true);
    canvas.getContext("2d")?.clearRect(0, 0, canvas.width, canvas.height);
    setMaskDirty(false);
  }

  function undoMask() {
    const canvas = maskCanvasRef.current;
    const stack = canvas ? undoStack(canvas) : [];
    const snapshot = stack.pop();
    if (!canvas || !snapshot || isSending) return;

    canvas.getContext("2d")?.putImageData(snapshot, 0, 0);
    setCanUndo(stack.length > 0);
    setMaskDirty(!canvasIsBlank(canvas));
  }

  return (
    <section
      className="image-preview-dialog"
      role="dialog"
      aria-modal="true"
      aria-label={fileName}
      ref={modalDialogRef}
    >
      <header className="image-preview-topbar" onMouseDown={(event) => event.stopPropagation()}>
        <div className="image-preview-title">
          <button
            className="icon-button ghost"
            type="button"
            title={t("preview.close")}
            aria-label={t("preview.close")}
            onClick={onClose}
            ref={closeButtonRef}
          >
            <X size={17} />
          </button>
          <strong title={fileName}>{fileName}</strong>
        </div>
        <div className="image-preview-actions">
          <IconButton
            className={maskMode ? "active" : ""}
            label={maskMode ? t("preview.close_mask") : t("preview.edit_mask")}
            onClick={() => setMaskMode((open) => !open)}
            disabled={isSending}
          >
            <Brush size={16} />
          </IconButton>
          <IconButton label={t("preview.reference", { name: fileName })} onClick={() => onReference(asset.id)}>
            <Paperclip size={16} />
          </IconButton>
          <IconButton label={t("preview.open_folder", { name: fileName })} onClick={() => onReveal(asset.id)}>
            <FolderOpen size={16} />
          </IconButton>
          <IconButton label={t("preview.copy_path", { name: fileName })} onClick={() => onCopyPath(asset.id)}>
            <Copy size={16} />
          </IconButton>
        </div>
      </header>

      <main className="image-preview-stage" onMouseDown={closeOnStage}>
        {maskMode ? (
          <div className="image-preview-mask-toolbar" onMouseDown={(event) => event.stopPropagation()}>
            <IconButton
              className={maskTool === "brush" ? "active" : ""}
              label={t("preview.brush")}
              onClick={() => setMaskTool("brush")}
              disabled={isSending}
            >
              <Brush size={15} />
            </IconButton>
            <IconButton
              className={maskTool === "erase" ? "active" : ""}
              label={t("preview.erase")}
              onClick={() => setMaskTool("erase")}
              disabled={isSending}
            >
              <Eraser size={15} />
            </IconButton>
            <label className="image-preview-brush-size" title={t("preview.size_title", { size: brushSize })}>
              <span>{t("preview.size")}</span>
              <input
                type="range"
                min="8"
                max="140"
                step="1"
                value={brushSize}
                disabled={isSending}
                onChange={(event) => setBrushSize(Number(event.target.value))}
              />
            </label>
            <IconButton label={t("preview.undo_mask")} onClick={undoMask} disabled={isSending || !canUndo}>
              <Undo2 size={15} />
            </IconButton>
            <IconButton label={t("preview.clear_mask")} onClick={clearMask} disabled={isSending || !maskDirty}>
              <Trash2 size={15} />
            </IconButton>
          </div>
        ) : null}
        <div
          className={`image-preview-image-wrap ${maskMode ? "masking" : ""}`}
          onMouseDown={(event) => event.stopPropagation()}
        >
          <img alt={fileName} src={previewUrl(asset)} draggable="false" onLoad={handleImageLoad} />
          <canvas
            className={`image-preview-mask-canvas ${maskMode ? "active" : ""} ${maskDirty ? "dirty" : ""}`}
            ref={maskCanvasRef}
            width={canvasWidth}
            height={canvasHeight}
            aria-label={t("preview.mask")}
            onPointerDown={startMaskStroke}
            onPointerMove={moveMaskStroke}
            onPointerUp={endMaskStroke}
            onPointerCancel={endMaskStroke}
          />
        </div>
      </main>

      <footer className="image-preview-composer" onMouseDown={(event) => event.stopPropagation()}>
        <PromptEditor
          value={prompt}
          onChange={onPromptChange}
          onSubmit={handleSend}
          disabled={isSending}
          placeholderText={t("preview.prompt_placeholder", {}, "Describe the edit you want...")}
        />
        <button
          className="send-button image-preview-send"
          type="button"
          title={isSending ? t("preview.sending") : t("common.send")}
          aria-label={isSending ? t("preview.sending") : t("common.send")}
          onClick={handleSend}
          disabled={sendDisabled}
        >
          <Send size={17} />
        </button>
      </footer>
    </section>
  );
}

function positiveNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) && number > 0 ? number : null;
}

function canvasPoint(event, canvas) {
  if (!canvas) return null;

  const rect = canvas.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0) return null;

  return {
    x: clamp(((event.clientX - rect.left) / rect.width) * canvas.width, 0, canvas.width),
    y: clamp(((event.clientY - rect.top) / rect.height) * canvas.height, 0, canvas.height),
  };
}

function drawMaskSegment(canvas, from, to, stroke) {
  const context = canvas.getContext("2d");
  if (!context) return;

  context.save();
  context.lineCap = "round";
  context.lineJoin = "round";
  context.lineWidth = stroke.size;

  if (stroke.tool === "erase") {
    context.globalCompositeOperation = "destination-out";
    context.strokeStyle = "rgba(0, 0, 0, 1)";
    context.fillStyle = "rgba(0, 0, 0, 1)";
  } else {
    context.globalCompositeOperation = "source-over";
    context.strokeStyle = "rgba(37, 99, 235, 0.42)";
    context.fillStyle = "rgba(37, 99, 235, 0.42)";
  }

  context.beginPath();
  if (from.x === to.x && from.y === to.y) {
    context.arc(to.x, to.y, stroke.size / 2, 0, Math.PI * 2);
    context.fill();
  } else {
    context.moveTo(from.x, from.y);
    context.lineTo(to.x, to.y);
    context.stroke();
  }
  context.restore();
}

function saveUndoSnapshot(canvas) {
  const context = canvas.getContext("2d");
  if (!context) return;

  const stack = undoStack(canvas);
  stack.push(context.getImageData(0, 0, canvas.width, canvas.height));
  while (stack.length > 24) stack.shift();
}

function undoStack(canvas) {
  const stack = canvas.__avcsUndoStack || [];
  canvas.__avcsUndoStack = stack;
  return stack;
}

function canvasIsBlank(canvas) {
  const data = canvas.getContext("2d")?.getImageData(0, 0, canvas.width, canvas.height).data;
  if (!data) return true;

  for (let index = 3; index < data.length; index += 4) {
    if (data[index] > 0) return false;
  }

  return true;
}

async function exportMaskFile(canvas, fileName) {
  if (!canvas) throw new Error("Mask canvas is unavailable.");

  const sourceContext = canvas.getContext("2d");
  if (!sourceContext) throw new Error("Mask canvas is unavailable.");

  const source = sourceContext.getImageData(0, 0, canvas.width, canvas.height);
  const targetCanvas = document.createElement("canvas");
  targetCanvas.width = canvas.width;
  targetCanvas.height = canvas.height;

  const targetContext = targetCanvas.getContext("2d");
  if (!targetContext) throw new Error("Mask export is unavailable.");

  const target = targetContext.createImageData(canvas.width, canvas.height);

  for (let index = 0; index < source.data.length; index += 4) {
    const marked = source.data[index + 3] > 0;
    const value = marked ? 255 : 0;
    target.data[index] = value;
    target.data[index + 1] = value;
    target.data[index + 2] = value;
    target.data[index + 3] = marked ? 0 : 255;
  }

  targetContext.putImageData(target, 0, 0);

  const blob = await new Promise((resolve) => targetCanvas.toBlob(resolve, "image/png"));
  if (!blob) throw new Error("Mask export failed.");

  return new File([blob], maskFileName(fileName), {
    type: "image/png",
    lastModified: Date.now(),
  });
}

function maskFileName(fileName) {
  const base = String(fileName || "image")
    .replace(/\.[^.]+$/, "")
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");

  return `${base || "image"}-mask.png`;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}
