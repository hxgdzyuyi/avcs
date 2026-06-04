import { useId, useRef } from "react";
import { AlertTriangle, Info, X } from "lucide-react";
import IconButton from "./IconButton.jsx";
import { useModalDialog } from "./useModalDialog.js";

export default function ConfirmDialog({
  title,
  message,
  confirmLabel = "Confirm",
  cancelLabel = "Cancel",
  tone = "default",
  onConfirm,
  onCancel,
}) {
  const cancelButtonRef = useRef(null);
  const titleId = useId();
  const messageId = useId();
  const isDanger = tone === "danger";
  const Icon = isDanger ? AlertTriangle : Info;
  const dialogRef = useModalDialog({
    onCancel,
    initialFocusRef: cancelButtonRef,
  });

  function closeOnBackdrop(event) {
    if (event.target === event.currentTarget) onCancel?.();
  }

  return (
    <section
      className="confirm-dialog-backdrop"
      onMouseDown={closeOnBackdrop}
    >
      <div
        className={`confirm-dialog ${isDanger ? "danger" : ""}`}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={message ? messageId : undefined}
        ref={dialogRef}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="confirm-dialog-header">
          <span className="confirm-dialog-icon" aria-hidden="true">
            <Icon size={17} />
          </span>
          <div className="confirm-dialog-copy">
            <h2 id={titleId}>{title}</h2>
            {message ? <p id={messageId}>{message}</p> : null}
          </div>
          <IconButton
            label="Close confirmation"
            className="ghost confirm-dialog-close"
            onClick={onCancel}
          >
            <X size={16} />
          </IconButton>
        </header>

        <footer className="confirm-dialog-actions">
          <button
            type="button"
            className="confirm-dialog-button"
            onClick={onCancel}
            ref={cancelButtonRef}
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            className={`confirm-dialog-button primary ${isDanger ? "danger" : ""}`}
            onClick={onConfirm}
          >
            {confirmLabel}
          </button>
        </footer>
      </div>
    </section>
  );
}
