import { useEffect, useRef } from "react";

export function useModalDialog({ onCancel, initialFocusRef }) {
  const dialogRef = useRef(null);
  const cancelRef = useRef(onCancel);

  useEffect(() => {
    cancelRef.current = onCancel;
  }, [onCancel]);

  useEffect(() => {
    const previousOverflow = document.body.style.overflow;
    const previousFocus = document.activeElement;

    document.body.style.overflow = "hidden";
    initialFocusRef?.current?.focus({ preventScroll: true });

    function handleKeyDown(event) {
      if (event.key === "Escape") {
        event.preventDefault();
        cancelRef.current?.();
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
  }, [initialFocusRef]);

  return dialogRef;
}

function trapFocus(event, container) {
  if (!container) return;

  const elements = focusableElements(container);
  if (elements.length === 0) {
    event.preventDefault();
    container.focus?.();
    return;
  }

  const first = elements[0];
  const last = elements[elements.length - 1];
  const active = document.activeElement;

  if (event.shiftKey && (!container.contains(active) || active === first)) {
    event.preventDefault();
    last.focus();
    return;
  }

  if (!event.shiftKey && active === last) {
    event.preventDefault();
    first.focus();
  }
}

function focusableElements(container) {
  return [
    ...container.querySelectorAll(
      [
        "a[href]",
        "button",
        "input",
        "select",
        "textarea",
        ".cm-content",
        '[tabindex]:not([tabindex="-1"])',
      ].join(","),
    ),
  ].filter((element) => {
    if (element.disabled || element.getAttribute("aria-hidden") === "true") {
      return false;
    }

    return Boolean(
      element.offsetWidth ||
        element.offsetHeight ||
        element.getClientRects().length,
    );
  });
}
