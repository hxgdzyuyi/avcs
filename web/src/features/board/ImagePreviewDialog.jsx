import { useEffect, useRef } from "react";
import { Copy, FolderOpen, Paperclip, Send, X } from "lucide-react";
import IconButton from "../../components/IconButton.jsx";
import PromptEditor from "../chat/PromptEditor.jsx";
import { previewUrl } from "../../api.js";

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
}) {
  const dialogRef = useRef(null);
  const closeButtonRef = useRef(null);
  const closeRef = useRef(onClose);
  const fileName = asset?.file_name || "Image";
  const sendDisabled = isSending || !prompt.trim();

  useEffect(() => {
    closeRef.current = onClose;
  }, [onClose]);

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    const previousFocus = document.activeElement;

    document.body.style.overflow = "hidden";
    closeButtonRef.current?.focus({ preventScroll: true });

    function handleKeyDown(event) {
      if (event.key === "Escape") {
        event.preventDefault();
        closeRef.current();
        return;
      }

      if (event.key === "Tab") trapFocus(event, dialogRef.current);
    }

    window.addEventListener("keydown", handleKeyDown);

    return () => {
      window.removeEventListener("keydown", handleKeyDown);
      document.body.style.overflow = previousOverflow;
      if (previousFocus instanceof HTMLElement) {
        previousFocus.focus({ preventScroll: true });
      }
    };
  }, []);

  function closeOnStage(event) {
    if (event.target === event.currentTarget) onClose();
  }

  return (
    <section
      className="image-preview-dialog"
      role="dialog"
      aria-modal="true"
      aria-label={fileName}
      ref={dialogRef}
    >
      <header className="image-preview-topbar" onMouseDown={(event) => event.stopPropagation()}>
        <div className="image-preview-title">
          <button
            className="icon-button ghost"
            type="button"
            title="Close image preview"
            aria-label="Close image preview"
            onClick={onClose}
            ref={closeButtonRef}
          >
            <X size={17} />
          </button>
          <strong title={fileName}>{fileName}</strong>
        </div>
        <div className="image-preview-actions">
          <IconButton label={`Reference ${fileName}`} onClick={() => onReference(asset.id)}>
            <Paperclip size={16} />
          </IconButton>
          <IconButton label={`Open containing folder for ${fileName}`} onClick={() => onReveal(asset.id)}>
            <FolderOpen size={16} />
          </IconButton>
          <IconButton label={`Copy path for ${fileName}`} onClick={() => onCopyPath(asset.id)}>
            <Copy size={16} />
          </IconButton>
        </div>
      </header>

      <main className="image-preview-stage" onMouseDown={closeOnStage}>
        <div className="image-preview-image-wrap" onMouseDown={(event) => event.stopPropagation()}>
          <img alt={fileName} src={previewUrl(asset)} draggable="false" />
        </div>
      </main>

      <footer className="image-preview-composer" onMouseDown={(event) => event.stopPropagation()}>
        <PromptEditor
          value={prompt}
          onChange={onPromptChange}
          onSubmit={onSend}
          disabled={isSending}
        />
        <button
          className="send-button image-preview-send"
          type="button"
          title={isSending ? "Sending" : "Send"}
          aria-label={isSending ? "Sending" : "Send"}
          onClick={onSend}
          disabled={sendDisabled}
        >
          <Send size={17} />
        </button>
      </footer>
    </section>
  );
}

function trapFocus(event, container) {
  if (!container) return;

  const focusable = Array.from(
    container.querySelectorAll(
      "a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex]:not([tabindex='-1']), .cm-content",
    ),
  ).filter((element) => element instanceof HTMLElement && !element.hasAttribute("disabled"));

  if (focusable.length === 0) {
    event.preventDefault();
    return;
  }

  const first = focusable[0];
  const last = focusable[focusable.length - 1];
  const active = document.activeElement;

  if (event.shiftKey) {
    if (active === first || !container.contains(active)) {
      event.preventDefault();
      last.focus();
    }
    return;
  }

  if (active === last || !container.contains(active)) {
    event.preventDefault();
    first.focus();
  }
}
