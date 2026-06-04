import { useId, useRef, useState } from "react";
import { PencilLine, X } from "lucide-react";
import IconButton from "./IconButton.jsx";
import { useModalDialog } from "./useModalDialog.js";

export default function PromptDialog({
  title,
  message,
  label,
  initialValue = "",
  placeholder = "",
  confirmLabel = "Save",
  cancelLabel = "Cancel",
  required = true,
  trimValue = true,
  onConfirm,
  onCancel,
}) {
  const [value, setValue] = useState(initialValue || "");
  const inputRef = useRef(null);
  const titleId = useId();
  const messageId = useId();
  const inputId = useId();
  const dialogRef = useModalDialog({
    onCancel,
    initialFocusRef: inputRef,
  });
  const resolvedValue = trimValue ? value.trim() : value;
  const confirmDisabled = required && resolvedValue.length === 0;

  function handleSubmit(event) {
    event.preventDefault();
    if (confirmDisabled) return;
    onConfirm?.(resolvedValue);
  }

  function handleInputFocus(event) {
    event.currentTarget.select();
  }

  return (
    <section className="confirm-dialog-backdrop" onMouseDown={closeOnBackdrop}>
      <form
        className="confirm-dialog prompt-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        aria-describedby={message ? messageId : undefined}
        ref={dialogRef}
        onMouseDown={(event) => event.stopPropagation()}
        onSubmit={handleSubmit}
      >
        <header className="confirm-dialog-header">
          <span className="confirm-dialog-icon" aria-hidden="true">
            <PencilLine size={17} />
          </span>
          <div className="confirm-dialog-copy">
            <h2 id={titleId}>{title}</h2>
            {message ? <p id={messageId}>{message}</p> : null}
          </div>
          <IconButton
            label="Close prompt"
            className="ghost confirm-dialog-close"
            onClick={onCancel}
          >
            <X size={16} />
          </IconButton>
        </header>

        <label className="prompt-dialog-field" htmlFor={inputId}>
          <span>{label}</span>
          <input
            id={inputId}
            ref={inputRef}
            value={value}
            placeholder={placeholder}
            onChange={(event) => setValue(event.target.value)}
            onFocus={handleInputFocus}
          />
        </label>

        <footer className="confirm-dialog-actions">
          <button
            type="button"
            className="confirm-dialog-button"
            onClick={onCancel}
          >
            {cancelLabel}
          </button>
          <button
            type="submit"
            className="confirm-dialog-button primary"
            disabled={confirmDisabled}
          >
            {confirmLabel}
          </button>
        </footer>
      </form>
    </section>
  );

  function closeOnBackdrop(event) {
    if (event.target === event.currentTarget) onCancel?.();
  }
}
