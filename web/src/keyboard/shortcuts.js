const EDITABLE_SELECTOR = [
  "input",
  "textarea",
  "select",
  "[contenteditable='true']",
  ".cm-editor",
  ".cm-content",
].join(",");

export const SHORTCUT_GUIDE_SECTIONS = [
  {
    id: "composer",
    title: "Composer",
    rows: [
      {
        action: "Insert newline",
        actionKey: "shortcuts.action.insert_newline",
        windows: "Shift+Enter",
        mac: "Shift+Enter",
      },
      {
        action: "Paste clipboard image as reference",
        actionKey: "shortcuts.action.paste_image",
        windows: "Ctrl+V",
        mac: "Cmd+V",
      },
      {
        action: "Send prompt",
        actionKey: "shortcuts.action.send_prompt",
        windows: "Enter or Ctrl+Enter",
        mac: "Enter or Cmd+Enter",
      },
    ],
  },
  {
    id: "board",
    title: "Board",
    rows: [
      { action: "Select tool", actionKey: "shortcuts.action.select_tool", windows: "V", mac: "V" },
      { action: "Hand tool", actionKey: "shortcuts.action.hand_tool", windows: "H", mac: "H" },
      {
        action: "Temporary pan",
        actionKey: "shortcuts.action.temporary_pan",
        windows: "Hold Space + drag",
        mac: "Hold Space + drag",
      },
      { action: "Zoom", actionKey: "shortcuts.action.zoom", windows: "Ctrl + wheel", mac: "Cmd + wheel" },
      { action: "Fit selected", actionKey: "shortcuts.action.fit_selected", windows: "Shift+2", mac: "Shift+2" },
      { action: "Fit all", actionKey: "shortcuts.action.fit_all", windows: "Ctrl+0", mac: "Cmd+0" },
      { action: "Show or hide UI", actionKey: "shortcuts.action.toggle_ui", windows: "Ctrl+\\", mac: "Cmd+\\" },
      { action: "Undo board edit", actionKey: "shortcuts.action.undo_board", windows: "Ctrl+Z", mac: "Cmd+Z" },
      {
        action: "Redo board edit",
        actionKey: "shortcuts.action.redo_board",
        windows: "Ctrl+Shift+Z or Ctrl+Y",
        mac: "Cmd+Shift+Z",
      },
      {
        action: "Delete selected output image",
        actionKey: "shortcuts.action.delete_selected",
        windows: "Delete or Backspace",
        mac: "Delete or Backspace",
      },
    ],
  },
  {
    id: "layers",
    title: "Layers",
    rows: [
      { action: "Bring forward", actionKey: "shortcuts.action.bring_forward", windows: "]", mac: "]" },
      { action: "Send backward", actionKey: "shortcuts.action.send_backward", windows: "[", mac: "[" },
      { action: "Bring to front", actionKey: "shortcuts.action.bring_to_front", windows: "Shift+]", mac: "Shift+]" },
      { action: "Send to back", actionKey: "shortcuts.action.send_to_back", windows: "Shift+[", mac: "Shift+[" },
    ],
  },
  {
    id: "app",
    title: "App",
    rows: [
      { action: "Open shortcuts", actionKey: "shortcuts.action.open_shortcuts", windows: "Shift+?", mac: "Shift+?" },
    ],
  },
];

export function isEditableTarget(target) {
  if (typeof Element === "undefined" || !(target instanceof Element)) {
    return false;
  }

  if (target.matches(EDITABLE_SELECTOR)) return true;
  if (target.isContentEditable) return true;

  return Boolean(target.closest(EDITABLE_SELECTOR));
}

export function hasOpenModal() {
  if (typeof document === "undefined") return false;
  return Boolean(document.querySelector("[aria-modal='true']"));
}

export function isMacPlatform(platform = defaultPlatform()) {
  return /Mac|iPhone|iPad|iPod/i.test(platform || "");
}

export function platformModifierLabel(platform = defaultPlatform()) {
  return isMacPlatform(platform) ? "Cmd" : "Ctrl";
}

export function shortcutLabel(shortcut, platform = defaultPlatform()) {
  if (!shortcut) return "";

  const parts = [];
  if (shortcut.mod) parts.push(platformModifierLabel(platform));
  if (shortcut.ctrl) parts.push("Ctrl");
  if (shortcut.meta) parts.push("Cmd");
  if (shortcut.shift) parts.push("Shift");
  if (shortcut.alt) parts.push("Alt");
  parts.push(labelForKey(shortcut.key));

  return parts.join("+");
}

export function matchesShortcut(event, shortcut) {
  if (!event || !shortcut) return false;

  const keyMatches = normalizeKey(event.key) === normalizeKey(shortcut.key);
  if (!keyMatches) return false;

  const usesMacMod = Boolean(shortcut.mod && isMacPlatform());
  const expectedCtrl = Boolean(shortcut.ctrl || (shortcut.mod && !usesMacMod));
  const expectedMeta = Boolean(shortcut.meta || usesMacMod);
  const expectedShift = Boolean(shortcut.shift);
  const expectedAlt = Boolean(shortcut.alt);

  if (Boolean(event.ctrlKey) !== expectedCtrl) return false;
  if (Boolean(event.metaKey) !== expectedMeta) return false;
  if (Boolean(event.shiftKey) !== expectedShift) return false;
  if (Boolean(event.altKey) !== expectedAlt) return false;

  return true;
}

export function isShortcutGuideShortcut(event) {
  if (!event?.shiftKey || event.ctrlKey || event.metaKey || event.altKey) {
    return false;
  }

  return event.key === "?" || event.key === "/";
}

export function shouldIgnoreGlobalShortcut(
  event,
  { allowEditable = false, allowModal = false } = {},
) {
  if (!event) return true;
  if (event.defaultPrevented) return true;
  if (event.isComposing || event.keyCode === 229) return true;
  if (!allowEditable && isEditableTarget(event.target)) return true;
  if (!allowModal && hasOpenModal()) return true;
  return false;
}

function defaultPlatform() {
  if (typeof navigator === "undefined") return "";
  return navigator.userAgentData?.platform || navigator.platform || "";
}

function normalizeKey(key) {
  if (key === " " || key === "Spacebar" || key === "Space") return "space";
  if (key === "Esc") return "escape";
  return String(key || "").toLowerCase();
}

function labelForKey(key) {
  if (key === " " || key === "Spacebar" || key === "Space") return "Space";
  if (key === "\\") return "\\";
  return String(key || "").toUpperCase();
}
