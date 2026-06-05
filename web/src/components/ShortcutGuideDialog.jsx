import { useId, useRef } from "react";
import { Keyboard, X } from "lucide-react";
import IconButton from "./IconButton.jsx";
import { useModalDialog } from "./useModalDialog.js";
import {
  isMacPlatform,
  SHORTCUT_GUIDE_SECTIONS,
} from "../keyboard/shortcuts.js";

const defaultT = (key, _params = {}, fallback = key) => fallback;

export default function ShortcutGuideDialog({ onClose, t = defaultT }) {
  const closeButtonRef = useRef(null);
  const titleId = useId();
  const dialogRef = useModalDialog({
    onCancel: onClose,
    initialFocusRef: closeButtonRef,
  });
  const currentPlatform = isMacPlatform() ? "mac" : "windows";

  function closeOnBackdrop(event) {
    if (event.target === event.currentTarget) onClose?.();
  }

  return (
    <section
      className="shortcut-guide-backdrop"
      onMouseDown={closeOnBackdrop}
    >
      <div
        className="shortcut-guide-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        ref={dialogRef}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="shortcut-guide-header">
          <span className="shortcut-guide-icon" aria-hidden="true">
            <Keyboard size={17} />
          </span>
          <div>
            <h2 id={titleId}>{t("shortcuts.title")}</h2>
            <small>{currentPlatform === "mac" ? "Mac" : "Windows / Linux"}</small>
          </div>
          <IconButton
            label={t("shortcuts.close")}
            className="ghost"
            onClick={onClose}
            ref={closeButtonRef}
          >
            <X size={16} />
          </IconButton>
        </header>

        <div className="shortcut-guide-content">
          {SHORTCUT_GUIDE_SECTIONS.map((section) => (
            <section className="shortcut-guide-section" key={section.id}>
              <h3>{t(`shortcuts.section.${section.id}`, {}, section.title)}</h3>
              <div className="shortcut-guide-grid" role="table">
                <div className="shortcut-guide-row heading" role="row">
                  <span role="columnheader">{t("shortcuts.action")}</span>
                  <span role="columnheader">Windows / Linux</span>
                  <span role="columnheader">Mac</span>
                </div>
                {section.rows.map((row) => (
                  <div className="shortcut-guide-row" role="row" key={row.action}>
                    <span role="cell">
                      {t(row.actionKey, {}, row.action)}
                    </span>
                    <ShortcutKeys value={row.windows} muted={currentPlatform === "mac"} t={t} />
                    <ShortcutKeys value={row.mac} muted={currentPlatform !== "mac"} t={t} />
                  </div>
                ))}
              </div>
            </section>
          ))}
        </div>
      </div>
    </section>
  );
}

function ShortcutKeys({ value, muted = false, t = defaultT }) {
  return (
    <span className={`shortcut-guide-keys${muted ? " muted" : ""}`} role="cell">
      {String(value)
        .split(" or ")
        .map((part, index) => (
          <span className="shortcut-guide-key-part" key={`${part}-${index}`}>
            {index > 0 ? (
              <span className="shortcut-guide-or">{t("shortcuts.or")}</span>
            ) : null}
            <kbd>{part}</kbd>
          </span>
        ))}
    </span>
  );
}
