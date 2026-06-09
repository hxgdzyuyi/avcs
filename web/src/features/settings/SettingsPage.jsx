import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, RotateCcw, Save, Settings as SettingsIcon, X } from "lucide-react";
import IconButton from "../../components/IconButton.jsx";
import { SUPPORTED_LOCALES } from "../../i18n.js";

const GROUPS = [
  ["agent", "Agent", "settings.group.agent"],
  ["providers", "Providers", "settings.group.providers"],
  ["images", "Images", "settings.group.images"],
  ["projects", "Projects", "settings.group.projects"],
  ["assets", "Assets", "settings.group.assets"],
  ["ui", "UI", "settings.group.ui"],
];

const SETTING_DEFS = [
  {
    key: "agent.harness",
    group: "agent",
    label: "Harness",
    labelKey: "settings.setting.agent_harness",
    type: "select",
    options: [
      ["auto", "Auto", "settings.option.harness_auto"],
      ["codex", "Codex Agent", "settings.option.harness_codex"],
      ["avcs_agent", "AvcsAgent", "settings.option.harness_avcs_agent"],
    ],
  },
  {
    key: "agent.default_model",
    group: "agent",
    label: "Model",
    labelKey: "settings.setting.agent_default_model",
    type: "model",
  },
  {
    key: "agent.default_effort",
    group: "agent",
    label: "Reasoning effort",
    labelKey: "settings.setting.agent_default_effort",
    type: "select",
    codexOnly: true,
    options: [
      ["", "Codex config", "settings.option.codex_config"],
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
    labelKey: "settings.setting.agent_default_approval_policy",
    type: "select",
    codexOnly: true,
    options: [
      ["never", "No approval", "settings.option.no_approval"],
      ["on-request", "On request", "settings.option.on_request"],
      ["on-failure", "On failure", "settings.option.on_failure"],
      ["untrusted", "Untrusted", "settings.option.untrusted"],
    ],
  },
  {
    key: "agent.default_sandbox_mode",
    group: "agent",
    label: "Sandbox mode",
    labelKey: "settings.setting.agent_default_sandbox_mode",
    type: "select",
    codexOnly: true,
    options: [
      ["workspace-write", "Workspace write", "settings.option.workspace_write"],
      ["read-only", "Read only", "settings.option.read_only"],
      ["danger-full-access", "Full access", "settings.option.full_access"],
    ],
  },
  {
    key: "agent.avcs_agent.text_model",
    group: "agent",
    label: "AvcsAgent text model",
    labelKey: "settings.setting.avcs_agent_text_model",
    type: "text",
  },
  {
    key: "agent.avcs_agent.image_model",
    group: "agent",
    label: "AvcsAgent image model",
    labelKey: "settings.setting.avcs_agent_image_model",
    type: "text",
  },
  {
    key: "agent.avcs_agent.max_tool_steps",
    group: "agent",
    label: "AvcsAgent max tool steps",
    labelKey: "settings.setting.avcs_agent_max_tool_steps",
    type: "number",
    min: 1,
    max: 10,
    step: 1,
  },
  {
    key: "agent.avcs_agent.compact_threshold",
    group: "agent",
    label: "AvcsAgent compact threshold",
    labelKey: "settings.setting.avcs_agent_compact_threshold",
    type: "number",
    min: 0.1,
    max: 0.95,
    step: 0.05,
  },
  {
    key: "agent.avcs_agent.base_url",
    group: "providers",
    label: "AvcsAgent base URL",
    labelKey: "settings.setting.avcs_agent_base_url",
    type: "text",
  },
  {
    key: "providers.vercel_ai_gateway.api_key",
    group: "providers",
    label: "Vercel AI Gateway API key",
    labelKey: "settings.setting.vercel_ai_gateway_api_key",
    type: "secret",
  },
  {
    key: "image.default_ratio",
    group: "images",
    label: "Default ratio",
    labelKey: "settings.setting.image_default_ratio",
    type: "select",
    options: [
      ["auto", "Auto", "settings.option.auto"],
      ["1:1", "1:1"],
      ["16:9", "16:9"],
      ["9:16", "9:16"],
      ["4:3", "4:3"],
      ["3:4", "3:4"],
      ["3:1", "3:1"],
      ["1:3", "1:3"],
    ],
  },
  {
    key: "image.default_count",
    group: "images",
    label: "Default count",
    labelKey: "settings.setting.image_default_count",
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
    labelKey: "settings.setting.image_transparent_background",
    type: "checkbox",
  },
  {
    key: "projects.default_root",
    group: "projects",
    label: "Default project folder",
    labelKey: "settings.setting.projects_default_root",
    type: "text",
  },
  {
    key: "projects.restore_last_opened",
    group: "projects",
    label: "Restore last opened project",
    labelKey: "settings.setting.projects_restore_last_opened",
    type: "checkbox",
  },
  {
    key: "assets.scan_on_open",
    group: "assets",
    label: "Scan project images on open",
    labelKey: "settings.setting.assets_scan_on_open",
    type: "checkbox",
  },
  {
    key: "ui.locale",
    group: "ui",
    label: "Language",
    labelKey: "settings.setting.ui_locale",
    type: "select",
    options: SUPPORTED_LOCALES.map((locale) => [
      locale.value,
      locale.label,
      locale.labelKey,
    ]),
  },
];

const DEFAULT_SETTINGS = {
  "agent.harness": "codex",
  "agent.default_model": "gpt-5.5",
  "agent.default_effort": "medium",
  "agent.default_approval_policy": "never",
  "agent.default_sandbox_mode": "workspace-write",
  "agent.avcs_agent.base_url": "https://ai-gateway.vercel.sh/v1",
  "agent.avcs_agent.text_model": "deepseek/deepseek-v4-pro",
  "agent.avcs_agent.image_model": "openai/gpt-image-2",
  "agent.avcs_agent.max_tool_steps": 3,
  "agent.avcs_agent.compact_threshold": 0.75,
  "providers.vercel_ai_gateway.api_key": null,
  "image.default_ratio": "auto",
  "image.default_count": 1,
  "image.transparent_background": false,
  "projects.default_root": "~/Documents/Avcs",
  "projects.restore_last_opened": true,
  "assets.scan_on_open": false,
  "ui.locale": "en",
};

const defaultT = (key, _params = {}, fallback = key) => fallback;

export default function SettingsPage({
  settingsItems = [],
  settings = {},
  modelOptions = [],
  connectionState,
  t = defaultT,
  onSave,
  onReset,
  onTestAvcsAgent,
  onBack,
  onConfirm = async () => false,
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
  const [testingAvcsAgent, setTestingAvcsAgent] = useState(false);
  const [testResult, setTestResult] = useState("");
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
    if (dirty) {
      const confirmed = await onConfirm({
        title: t("settings.confirm.discard_title"),
        message: t("settings.confirm.discard_message"),
        confirmLabel: t("common.discard"),
        tone: "danger",
      });
      if (!confirmed) return;
    }

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

  async function handleBack() {
    if (dirty) {
      const confirmed = await onConfirm({
        title: t("settings.confirm.back_title"),
        message: t("settings.confirm.back_message"),
        confirmLabel: t("common.discard"),
        tone: "danger",
      });
      if (!confirmed) return;
    }

    onBack();
  }

  async function handleTestAvcsAgent() {
    if (!onTestAvcsAgent || testingAvcsAgent || connectionState !== "online") return;

    setTestingAvcsAgent(true);
    setTestResult("");
    setError("");

    try {
      const result = await onTestAvcsAgent();
      const count = result?.models_count;
      setTestResult(
        typeof count === "number"
          ? t("settings.avcs_agent_test_ok_models", { count })
          : t("settings.avcs_agent_test_ok"),
      );
    } catch (testError) {
      setError(testError.message);
    } finally {
      setTestingAvcsAgent(false);
    }
  }

  return (
    <div className="settings-page">
      <header className="settings-header">
        <div className="settings-header-left">
          <IconButton label={t("settings.action.back")} onClick={handleBack}>
            <ArrowLeft size={17} />
          </IconButton>
          <div>
            <span className="eyebrow">Avcs</span>
            <h1>{t("settings.title")}</h1>
          </div>
        </div>
        <div className="settings-header-status">
          <span className={`connection-dot ${connectionState}`} />
          <span>{t(`connection.${connectionState}`, {}, connectionState)}</span>
        </div>
      </header>

      <main className="settings-shell">
        <nav className="settings-nav" aria-label={t("settings.nav_aria")}>
          {GROUPS.map(([key, label, labelKey]) => (
            <button
              className={activeGroup === key ? "active" : ""}
              type="button"
              key={key}
              onClick={() => setActiveGroup(key)}
            >
              <SettingsIcon size={15} />
              <span>{t(labelKey, {}, label)}</span>
            </button>
          ))}
        </nav>

        <section className="settings-panel">
          <form className="settings-form" onSubmit={handleSave}>
            <div className="settings-group-header">
              <div>
                <span className="eyebrow">{t("common.global")}</span>
                <h2>{groupLabel(activeGroup, t)}</h2>
              </div>
              <div className="settings-form-actions">
                <button
                  className="settings-action secondary"
                  type="button"
                  disabled={!dirty || saving}
                  onClick={() => setDraft(confirmed)}
                >
                  <X size={14} />
                  <span>{t("settings.action.cancel")}</span>
                </button>
                <button
                  className="settings-action secondary"
                  type="button"
                  disabled={!dirty || saving}
                  onClick={() => setDraft(confirmed)}
                >
                  <RotateCcw size={14} />
                  <span>{t("settings.action.reset_changed")}</span>
                </button>
                <button
                  className="settings-action primary"
                  type="submit"
                  disabled={!dirty || saving || connectionState !== "online"}
                >
                  <Save size={14} />
                  <span>{saving ? t("common.saving") : t("common.save")}</span>
                </button>
              </div>
            </div>

            <div className="settings-list">
              {activeDefs.map((definition) => {
                const item = itemsByKey.get(definition.key);
                const changed = !sameValue(draft[definition.key], confirmed[definition.key]);
                const stateKey = changed ? "modified" : item?.is_default ? "default" : "custom";
                const stateLabel = t(`common.${stateKey}`);

                return (
                  <div className="settings-row" key={definition.key}>
                    <div className="settings-row-meta">
                      <label htmlFor={settingInputId(definition.key)}>
                        {definitionLabel(definition, t)}
                      </label>
                      <span className={stateKey}>{stateLabel}</span>
                    </div>
                    <div className="settings-row-control">
                      {renderControl(
                        definition,
                        draft,
                        patchDraft,
                        modelSelectOptions,
                        t,
                        item,
                      )}
                    </div>
                    <button
                      className="settings-row-reset"
                      type="button"
                      disabled={Boolean(item?.is_default) || resettingKey === definition.key}
                      onClick={() => handleResetKey(definition.key)}
                    >
                      <RotateCcw size={13} />
                      <span>
                        {resettingKey === definition.key
                          ? t("common.resetting")
                          : t("common.reset")}
                      </span>
                    </button>
                  </div>
                );
              })}
            </div>

            {activeGroup === "providers" ? (
              <div className="settings-inline-test">
                <button
                  className="settings-action secondary"
                  type="button"
                  disabled={!onTestAvcsAgent || testingAvcsAgent || connectionState !== "online"}
                  onClick={handleTestAvcsAgent}
                >
                  <span>
                    {testingAvcsAgent
                      ? t("settings.action.testing")
                      : t("settings.action.test_avcs_agent")}
                  </span>
                </button>
                {testResult ? <span className="configured">{testResult}</span> : null}
              </div>
            ) : null}

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

function renderControl(definition, draft, patchDraft, modelSelectOptions, t, item) {
  const value = draft[definition.key];
  const inputId = settingInputId(definition.key);
  const disabled = Boolean(
    definition.codexOnly && draft["agent.harness"] === "avcs_agent",
  );

  if (definition.type === "checkbox") {
    return (
      <label className="settings-toggle">
        <input
          id={inputId}
          type="checkbox"
          checked={Boolean(value)}
          disabled={disabled}
          onChange={(event) => patchDraft(definition.key, event.target.checked)}
        />
        <span>{Boolean(value) ? t("common.on") : t("common.off")}</span>
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
          placeholder={t("settings.option.codex_config")}
          autoComplete="off"
          disabled={disabled}
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

  if (definition.type === "secret") {
    const configured = Boolean(item?.has_value);
    const maskedValue = item?.masked_value || "";

    return (
      <div className="settings-secret-control">
        <input
          id={inputId}
          className="settings-input"
          type="password"
          value={value || ""}
          placeholder={
            configured
              ? t("settings.secret.keep_existing")
              : t("settings.secret.not_configured")
          }
          autoComplete="new-password"
          disabled={disabled}
          onChange={(event) => patchDraft(definition.key, event.target.value)}
        />
        <span className={configured ? "configured" : ""}>
          {configured
            ? [t("settings.secret.configured"), maskedValue].filter(Boolean).join(" - ")
            : t("settings.secret.empty")}
        </span>
      </div>
    );
  }

  if (definition.type === "text") {
    return (
      <input
        id={inputId}
        className="settings-input"
        value={value || ""}
        autoComplete="off"
        disabled={disabled}
        onChange={(event) => patchDraft(definition.key, event.target.value)}
      />
    );
  }

  if (definition.type === "number") {
    return (
      <input
        id={inputId}
        className="settings-input"
        type="number"
        min={definition.min}
        max={definition.max}
        step={definition.step}
        value={value ?? ""}
        autoComplete="off"
        disabled={disabled}
        onChange={(event) => patchDraft(definition.key, event.target.value)}
      />
    );
  }

  return (
    <select
      id={inputId}
      className="settings-input"
      value={value ?? ""}
      disabled={disabled}
      onChange={(event) => {
        const selected = definition.options.find(
          ([optionValue]) => String(optionValue) === event.target.value,
        );
        patchDraft(definition.key, selected ? selected[0] : event.target.value);
      }}
    >
      {definition.options.map(([optionValue, optionLabel]) => (
        <option value={optionValue} key={`${definition.key}-${optionValue}`}>
          {optionLabelFor(definition, optionValue, optionLabel, t)}
        </option>
      ))}
    </select>
  );
}

function valuesFromSettings(items, settings) {
  const itemValues = new Map((items || []).map((item) => [item.key, item.value]));

  return Object.fromEntries(
    SETTING_DEFS.map((definition) => {
      if (definition.type === "secret") return [definition.key, ""];

      return [
        definition.key,
        Object.prototype.hasOwnProperty.call(settings || {}, definition.key)
          ? settings[definition.key]
          : itemValues.get(definition.key) ?? DEFAULT_SETTINGS[definition.key],
      ];
    }),
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

  if (definition.type === "secret") {
    return String(value || "").trim();
  }

  if (definition.key === "agent.default_effort") {
    return value || null;
  }

  if (definition.key === "image.default_count") {
    return Number(value) || 1;
  }

  if (definition.type === "number") {
    return Number(value);
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

function groupLabel(group, t) {
  const entry = GROUPS.find(([key]) => key === group);
  return entry ? t(entry[2], {}, entry[1]) : t("settings.title");
}

function definitionLabel(definition, t) {
  return t(definition.labelKey, {}, definition.label);
}

function optionLabelFor(definition, optionValue, optionLabel, t) {
  const option = definition.options.find(
    ([candidateValue]) => candidateValue === optionValue,
  );
  return t(option?.[2], {}, optionLabel);
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
