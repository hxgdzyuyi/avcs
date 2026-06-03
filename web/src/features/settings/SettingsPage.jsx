import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, RotateCcw, Save, Settings as SettingsIcon, X } from "lucide-react";
import IconButton from "../../components/IconButton.jsx";

const GROUPS = [
  ["agent", "Agent"],
  ["images", "Images"],
  ["projects", "Projects"],
  ["assets", "Assets"],
];

const SETTING_DEFS = [
  {
    key: "agent.default_model",
    group: "agent",
    label: "Model",
    type: "model",
  },
  {
    key: "agent.default_effort",
    group: "agent",
    label: "Reasoning effort",
    type: "select",
    options: [
      ["", "Codex config"],
      ["none", "none"],
      ["minimal", "minimal"],
      ["low", "low"],
      ["medium", "medium"],
      ["high", "high"],
      ["xhigh", "xhigh"],
    ],
  },
  {
    key: "agent.default_approval_policy",
    group: "agent",
    label: "Approval policy",
    type: "select",
    options: [
      ["never", "No approval"],
      ["on-request", "On request"],
      ["on-failure", "On failure"],
      ["untrusted", "Untrusted"],
    ],
  },
  {
    key: "agent.default_sandbox_mode",
    group: "agent",
    label: "Sandbox mode",
    type: "select",
    options: [
      ["workspace-write", "Workspace write"],
      ["read-only", "Read only"],
      ["danger-full-access", "Full access"],
    ],
  },
  {
    key: "image.default_ratio",
    group: "images",
    label: "Default ratio",
    type: "select",
    options: [
      ["auto", "Auto"],
      ["1:1", "1:1"],
      ["4:3", "4:3"],
      ["3:4", "3:4"],
      ["16:9", "16:9"],
      ["9:16", "9:16"],
    ],
  },
  {
    key: "image.default_count",
    group: "images",
    label: "Default count",
    type: "select",
    options: [
      [1, "1"],
      [2, "2"],
      [3, "3"],
      [4, "4"],
    ],
  },
  {
    key: "image.transparent_background",
    group: "images",
    label: "Transparent background",
    type: "checkbox",
  },
  {
    key: "projects.default_root",
    group: "projects",
    label: "Default project folder",
    type: "text",
  },
  {
    key: "projects.restore_last_opened",
    group: "projects",
    label: "Restore last opened project",
    type: "checkbox",
  },
  {
    key: "assets.scan_on_open",
    group: "assets",
    label: "Scan project images on open",
    type: "checkbox",
  },
];

const DEFAULT_SETTINGS = {
  "agent.default_model": "gpt-5.5",
  "agent.default_effort": "medium",
  "agent.default_approval_policy": "never",
  "agent.default_sandbox_mode": "workspace-write",
  "image.default_ratio": "auto",
  "image.default_count": 1,
  "image.transparent_background": false,
  "projects.default_root": "~/Documents/Avcs",
  "projects.restore_last_opened": true,
  "assets.scan_on_open": false,
};

export default function SettingsPage({
  settingsItems = [],
  settings = {},
  modelOptions = [],
  connectionState,
  onSave,
  onReset,
  onBack,
}) {
  const [activeGroup, setActiveGroup] = useState("agent");
  const [confirmed, setConfirmed] = useState(() =>
    valuesFromSettings(settingsItems, settings),
  );
  const [draft, setDraft] = useState(() =>
    valuesFromSettings(settingsItems, settings),
  );
  const [saving, setSaving] = useState(false);
  const [resettingKey, setResettingKey] = useState("");
  const [error, setError] = useState("");
  const itemsByKey = useMemo(
    () => new Map(settingsItems.map((item) => [item.key, item])),
    [settingsItems],
  );
  const dirty = settingsChanged(draft, confirmed);
  const activeDefs = SETTING_DEFS.filter((definition) => definition.group === activeGroup);
  const modelSelectOptions = modelOptionsForSelect(modelOptions);

  useEffect(() => {
    const next = valuesFromSettings(settingsItems, settings);
    setConfirmed(next);
    setDraft(next);
  }, [settingsItems, settings]);

  useEffect(() => {
    if (!dirty) return undefined;

    function handleBeforeUnload(event) {
      event.preventDefault();
      event.returnValue = "";
    }

    window.addEventListener("beforeunload", handleBeforeUnload);
    return () => window.removeEventListener("beforeunload", handleBeforeUnload);
  }, [dirty]);

  function patchDraft(key, value) {
    setError("");
    setDraft((current) => ({ ...current, [key]: value }));
  }

  async function handleSave(event) {
    event.preventDefault();
    if (!dirty || saving || connectionState !== "online") return;

    setSaving(true);
    setError("");

    try {
      await onSave(changedValues(draft, confirmed));
    } catch (saveError) {
      setError(saveError.message);
    } finally {
      setSaving(false);
    }
  }

  async function handleResetKey(key) {
    if (dirty && !window.confirm("Discard unsaved changes before resetting this setting?")) return;

    setResettingKey(key);
    setError("");

    try {
      await onReset([key]);
    } catch (resetError) {
      setError(resetError.message);
    } finally {
      setResettingKey("");
    }
  }

  function handleBack() {
    if (dirty && !window.confirm("Discard unsaved settings changes?")) return;
    onBack();
  }

  return (
    <div className="settings-page">
      <header className="settings-header">
        <div className="settings-header-left">
          <IconButton label="Back to workspace" onClick={handleBack}>
            <ArrowLeft size={17} />
          </IconButton>
          <div>
            <span className="eyebrow">Avcs</span>
            <h1>Settings</h1>
          </div>
        </div>
        <div className="settings-header-status">
          <span className={`connection-dot ${connectionState}`} />
          <span>{connectionState}</span>
        </div>
      </header>

      <main className="settings-shell">
        <nav className="settings-nav" aria-label="Settings groups">
          {GROUPS.map(([key, label]) => (
            <button
              className={activeGroup === key ? "active" : ""}
              type="button"
              key={key}
              onClick={() => setActiveGroup(key)}
            >
              <SettingsIcon size={15} />
              <span>{label}</span>
            </button>
          ))}
        </nav>

        <section className="settings-panel">
          <form className="settings-form" onSubmit={handleSave}>
            <div className="settings-group-header">
              <div>
                <span className="eyebrow">Global</span>
                <h2>{groupLabel(activeGroup)}</h2>
              </div>
              <div className="settings-form-actions">
                <button
                  className="settings-action secondary"
                  type="button"
                  disabled={!dirty || saving}
                  onClick={() => setDraft(confirmed)}
                >
                  <X size={14} />
                  <span>Cancel</span>
                </button>
                <button
                  className="settings-action secondary"
                  type="button"
                  disabled={!dirty || saving}
                  onClick={() => setDraft(confirmed)}
                >
                  <RotateCcw size={14} />
                  <span>Reset changed</span>
                </button>
                <button
                  className="settings-action primary"
                  type="submit"
                  disabled={!dirty || saving || connectionState !== "online"}
                >
                  <Save size={14} />
                  <span>{saving ? "Saving" : "Save"}</span>
                </button>
              </div>
            </div>

            <div className="settings-list">
              {activeDefs.map((definition) => {
                const item = itemsByKey.get(definition.key);
                const changed = !sameValue(draft[definition.key], confirmed[definition.key]);
                const stateLabel = changed ? "Modified" : item?.is_default ? "Default" : "Custom";

                return (
                  <div className="settings-row" key={definition.key}>
                    <div className="settings-row-meta">
                      <label htmlFor={settingInputId(definition.key)}>{definition.label}</label>
                      <span className={stateLabel.toLowerCase()}>{stateLabel}</span>
                    </div>
                    <div className="settings-row-control">
                      {renderControl(definition, draft, patchDraft, modelSelectOptions)}
                    </div>
                    <button
                      className="settings-row-reset"
                      type="button"
                      disabled={Boolean(item?.is_default) || resettingKey === definition.key}
                      onClick={() => handleResetKey(definition.key)}
                    >
                      <RotateCcw size={13} />
                      <span>{resettingKey === definition.key ? "Resetting" : "Reset"}</span>
                    </button>
                  </div>
                );
              })}
            </div>

            {error ? (
              <div className="settings-error" role="alert">
                {error}
              </div>
            ) : null}
          </form>
        </section>
      </main>
    </div>
  );
}

function renderControl(definition, draft, patchDraft, modelSelectOptions) {
  const value = draft[definition.key];
  const inputId = settingInputId(definition.key);

  if (definition.type === "checkbox") {
    return (
      <label className="settings-toggle">
        <input
          id={inputId}
          type="checkbox"
          checked={Boolean(value)}
          onChange={(event) => patchDraft(definition.key, event.target.checked)}
        />
        <span>{Boolean(value) ? "On" : "Off"}</span>
      </label>
    );
  }

  if (definition.type === "model") {
    return (
      <>
        <input
          id={inputId}
          className="settings-input"
          list="settings-model-options"
          value={value || ""}
          placeholder="Codex config"
          autoComplete="off"
          onChange={(event) => patchDraft(definition.key, event.target.value)}
        />
        <datalist id="settings-model-options">
          {modelSelectOptions.map(([optionValue, optionLabel]) => (
            <option value={optionValue} key={optionValue}>
              {optionLabel}
            </option>
          ))}
        </datalist>
      </>
    );
  }

  if (definition.type === "text") {
    return (
      <input
        id={inputId}
        className="settings-input"
        value={value || ""}
        autoComplete="off"
        onChange={(event) => patchDraft(definition.key, event.target.value)}
      />
    );
  }

  return (
    <select
      id={inputId}
      className="settings-input"
      value={value ?? ""}
      onChange={(event) => {
        const selected = definition.options.find(
          ([optionValue]) => String(optionValue) === event.target.value,
        );
        patchDraft(definition.key, selected ? selected[0] : event.target.value);
      }}
    >
      {definition.options.map(([optionValue, optionLabel]) => (
        <option value={optionValue} key={`${definition.key}-${optionValue}`}>
          {optionLabel}
        </option>
      ))}
    </select>
  );
}

function valuesFromSettings(items, settings) {
  const itemValues = new Map((items || []).map((item) => [item.key, item.value]));

  return Object.fromEntries(
    SETTING_DEFS.map((definition) => [
      definition.key,
      Object.prototype.hasOwnProperty.call(settings || {}, definition.key)
        ? settings[definition.key]
        : itemValues.get(definition.key) ?? DEFAULT_SETTINGS[definition.key],
    ]),
  );
}

function changedValues(draft, confirmed) {
  const changes = {};

  SETTING_DEFS.forEach((definition) => {
    const key = definition.key;
    if (sameValue(draft[key], confirmed[key])) return;
    changes[key] = normalizeDraftValue(definition, draft[key]);
  });

  return changes;
}

function normalizeDraftValue(definition, value) {
  if (definition.type === "model") {
    const clean = String(value || "").trim();
    return clean ? clean : null;
  }

  if (definition.key === "agent.default_effort") {
    return value || null;
  }

  if (definition.key === "image.default_count") {
    return Number(value) || 1;
  }

  if (definition.type === "text") {
    return String(value || "").trim();
  }

  return value;
}

function settingsChanged(draft, confirmed) {
  return SETTING_DEFS.some(
    (definition) => !sameValue(draft[definition.key], confirmed[definition.key]),
  );
}

function sameValue(first, second) {
  return JSON.stringify(first ?? null) === JSON.stringify(second ?? null);
}

function groupLabel(group) {
  return GROUPS.find(([key]) => key === group)?.[1] || "Settings";
}

function settingInputId(key) {
  return `setting-${key.replaceAll(".", "-")}`;
}

function modelOptionsForSelect(models) {
  const seen = new Set();

  return (models || []).flatMap((model) => {
    const value = model.model || model.id;
    if (!value || seen.has(value)) return [];
    seen.add(value);
    return [[value, model.displayName || value]];
  });
}
