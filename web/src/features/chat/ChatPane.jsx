import { useEffect, useState } from "react";
import {
  AlertCircle,
  Bot,
  Check,
  Copy,
  Image as ImageIcon,
  ImagePlus,
  LocateFixed,
  Pencil,
  RefreshCcw,
  ScanLine,
  Send,
  Settings2,
  ShieldAlert,
  TerminalSquare,
  Workflow,
  X,
} from "lucide-react";
import IconButton from "../../components/IconButton.jsx";
import PromptEditor from "./PromptEditor.jsx";
import { previewUrl } from "../../api.js";

const REASONING_EFFORTS = ["none", "minimal", "low", "medium", "high", "xhigh"];
const SANDBOX_PRESETS = [
  ["workspace-write", "Auto"],
  ["read-only", "Read Only"],
  ["danger-full-access", "Full Access"],
];
const APPROVAL_POLICIES = [
  ["never", "No approval"],
  ["on-request", "On request"],
  ["on-failure", "On failure"],
  ["untrusted", "Untrusted"],
];

export default function ChatPane({
  items,
  assets,
  references,
  prompt,
  setPrompt,
  onSend,
  onUpload,
  onScan,
  onOpenTracing,
  onRepairThread,
  onLocateAsset,
  onRemoveReference,
  agentRunning,
  threadRepairing,
  activeRun,
  streamingText,
  currentThread,
  isDraftThread,
  projectOpen,
  canUseChat,
  connectionState,
  modelOptions,
  composerSettings,
  onComposerSettingsChange,
  onApprovalRespond,
  onUpdateItem,
}) {
  const referencedAssets = references.map((id) => assets.find((asset) => asset.id === id)).filter(Boolean);
  const turns = groupTurns(items, activeRun, streamingText);
  const threadTitle = isDraftThread ? "新会话" : currentThread?.title || "No thread";
  const threadStatus = statusForThread(turns, agentRunning, currentThread, isDraftThread);
  const sendDisabled = !canUseChat || agentRunning || (!prompt.trim() && references.length === 0);

  return (
    <main className="chat-pane">
      <div className="pane-header thread-bar">
        <div className="thread-title">
          <h2 title={threadTitle}>{threadTitle}</h2>
          <span className={`agent-state ${threadStatus}`}>{threadStatus}</span>
        </div>
        <div className="toolbar">
          <IconButton
            label={threadRepairing ? "Repairing thread" : "Repair thread from Codex"}
            onClick={onRepairThread}
            disabled={!currentThread?.id || isDraftThread || agentRunning || threadRepairing}
          >
            <RefreshCcw size={17} />
          </IconButton>
          <IconButton label="View tracing" onClick={() => onOpenTracing(currentThread?.id)} disabled={!currentThread?.id || isDraftThread}>
            <Workflow size={17} />
          </IconButton>
          <IconButton label="Scan project images" onClick={onScan} disabled={!projectOpen}>
            <ScanLine size={17} />
          </IconButton>
        </div>
      </div>

      <div className="message-list">
        {!projectOpen ? (
          <div className="empty-chat">
            <strong>Open a project to start.</strong>
            <span>Threads, messages, and generated assets stay inside the selected folder.</span>
          </div>
        ) : connectionState !== "online" ? (
          <div className="empty-chat">
            <strong>WebSocket disconnected.</strong>
            <span>Recent messages remain visible; sending is disabled until the connection returns.</span>
          </div>
        ) : isDraftThread ? (
          <div className="empty-chat">
            <strong>准备新会话</strong>
            <span>发送第一条消息后才会创建 thread。</span>
          </div>
        ) : !currentThread ? (
          <div className="empty-chat">
            <strong>No thread.</strong>
            <span>Send a message to start a new one.</span>
          </div>
        ) : turns.length === 0 ? (
          <div className="empty-chat">
            <strong>No messages yet.</strong>
            <span>Describe the image you want to create.</span>
          </div>
        ) : null}

        {turns.map((turn) => (
          <section className={`turn ${turn.status}`} key={turn.id}>
            <div className="turn-meta">
              <span>{shortTurnId(turn.id)}</span>
              <span className={`turn-status ${turn.status}`}>{turn.status}</span>
              {turn.createdAt ? <time>{formatTime(turn.createdAt)}</time> : null}
            </div>

            <div className="turn-items">
              {turn.items.map((item) => (
                <article className={`message ${item.role || item.type}`} key={item.id}>
                  {renderItem(item, assets, onLocateAsset, onApprovalRespond, onUpdateItem)}
                </article>
              ))}

              {turn.streamingText ? (
                <article className="message assistant streaming">
                  <div className="assistant-body">
                    <span className="message-type">
                      <Bot size={13} />
                      assistant
                    </span>
                    <MessageBody content={turn.streamingText} canEdit={false} />
                  </div>
                </article>
              ) : null}

              {turn.status === "failed" && turn.error ? (
                <article className="message error">
                  <div className="error-block">
                    <AlertCircle size={15} />
                    <span>{turn.error}</span>
                  </div>
                </article>
              ) : null}
            </div>
          </section>
        ))}
      </div>

      <div className="composer">
        <div className="reference-strip">
          {referencedAssets.map((asset) => (
            <span className="reference-chip" key={asset.id}>
              <img alt="" src={previewUrl(asset)} />
              <span>{asset.file_name}</span>
              <IconButton label="Remove reference" onClick={() => onRemoveReference(asset.id)}>
                <X size={13} />
              </IconButton>
            </span>
          ))}
        </div>
        <PromptEditor value={prompt} onChange={setPrompt} onSubmit={onSend} disabled={!canUseChat} />
        <div className="composer-footer">
          <div className="composer-left">
            <label className={`composer-upload icon-button ${!projectOpen ? "disabled" : ""}`} title="Add image" aria-label="Add image" aria-disabled={!projectOpen}>
              <ImagePlus size={17} />
              <input type="file" accept="image/png,image/jpeg,image/gif,image/webp" onChange={onUpload} disabled={!projectOpen} />
            </label>
            <details className="composer-menu">
              <summary title="Custom settings" aria-label="Custom settings">
                <Settings2 size={14} />
                <span>Custom</span>
              </summary>
              <div className="composer-menu-panel">
                <ComposerSelect
                  compact={false}
                  label="Access"
                  value={composerSettings.sandbox_mode || "workspace-write"}
                  disabled={!projectOpen}
                  onChange={(value) => onComposerSettingsChange({ sandbox_mode: value })}
                  options={SANDBOX_PRESETS}
                />
                <ComposerSelect
                  compact={false}
                  label="Approval"
                  value={composerSettings.approval_policy || "never"}
                  disabled={!canUseChat}
                  onChange={(value) => onComposerSettingsChange({ approval_policy: value })}
                  options={APPROVAL_POLICIES}
                />
              </div>
            </details>
          </div>
          <div className="composer-right">
            <ComposerSelect
              label="Model"
              value={composerSettings.model || ""}
              disabled={!canUseChat}
              onChange={(value) => onComposerSettingsChange({ model: value })}
              options={[["", "Default model"], ...modelOptionsForSelect(modelOptions)]}
            />
            <ComposerSelect
              label="Effort"
              value={composerSettings.effort || ""}
              disabled={!canUseChat}
              onChange={(value) => onComposerSettingsChange({ effort: value })}
              options={[["", "Default effort"], ...REASONING_EFFORTS.map((effort) => [effort, effort])]}
            />
            <button
              className="send-button"
              type="button"
              title={agentRunning ? "Running" : "Send"}
              aria-label={agentRunning ? "Running" : "Send"}
              onClick={onSend}
              disabled={sendDisabled}
            >
              <Send size={17} />
            </button>
          </div>
        </div>
      </div>
    </main>
  );
}

function ComposerSelect({ label, value, options, disabled, onChange, compact = true }) {
  const selectedOption = options.find(([optionValue]) => optionValue === value);
  const title = `${label}: ${selectedOption?.[1] || value || "Default"}`;

  return (
    <label className={`composer-select composer-select-${label.toLowerCase()} ${compact ? "" : "composer-select-open"}`} title={title}>
      <span className="composer-select-label">{label}</span>
      <select aria-label={label} value={value} disabled={disabled} onChange={(event) => onChange(event.target.value)}>
        {options.map(([optionValue, optionLabel]) => (
          <option value={optionValue} key={`${label}-${optionValue}`}>
            {optionLabel}
          </option>
        ))}
      </select>
    </label>
  );
}

function renderItem(item, assets, onLocateAsset, onApprovalRespond, onUpdateItem) {
  if (item.type === "user_message") {
    return <UserMessageItem item={item} assets={assets} onUpdateItem={onUpdateItem} />;
  }

  if (item.type === "assistant_message") {
    return (
      <div className="assistant-body">
        <span className="message-type">
          <Bot size={13} />
          assistant
        </span>
        <MessageBody item={item} content={item.content || ""} onUpdateItem={onUpdateItem} />
      </div>
    );
  }

  if (item.type === "tool_call" || item.type === "tool_result") {
    return <ToolRow item={item} />;
  }

  if (item.type === "approval_request") {
    return <ApprovalCard item={item} onRespond={onApprovalRespond} />;
  }

  if (item.type === "image_asset") {
    const asset = assets.find((candidate) => candidate.id === item.payload?.asset_id);

    if (!asset) {
      return (
        <div className="asset-row missing">
          <span className="asset-row-icon">
            <ImageIcon size={16} />
          </span>
          <span>{item.content || "Missing image"}</span>
        </div>
      );
    }

    return (
      <button className="asset-row" type="button" onClick={() => onLocateAsset(asset.id)}>
        <span className="asset-row-icon">
          <ImageIcon size={16} />
        </span>
        <span>{asset.file_name}</span>
        <LocateFixed size={15} />
      </button>
    );
  }

  if (item.type === "error") {
    return (
      <div className="error-block">
        <AlertCircle size={15} />
        <span>{item.content || item.payload?.message || "Agent error"}</span>
      </div>
    );
  }

  return <MessageBody item={item} content={item.content || item.payload?.message || ""} onUpdateItem={onUpdateItem} />;
}

function UserMessageItem({ item, assets, onUpdateItem }) {
  const [isEditingMessage, setIsEditingMessage] = useState(false);
  const assetIds = Array.isArray(item.payload?.asset_ids) ? item.payload.asset_ids : [];

  return (
    <div className={`user-bubble${isEditingMessage ? " user-bubble-editing" : ""}`}>
      {item.content ? (
        <MessageBody
          item={item}
          content={item.content}
          onUpdateItem={onUpdateItem}
          onEditingChange={setIsEditingMessage}
        />
      ) : null}
      {assetIds.length > 0 ? <ReferencePreviewList assetIds={assetIds} assets={assets} /> : null}
    </div>
  );
}

function MessageBody({ item, content, onUpdateItem, canEdit = true, onEditingChange }) {
  const text = content || "";
  const editable = canEdit && item?.id && onUpdateItem;
  const [draft, setDraft] = useState(text);
  const [isEditing, setIsEditing] = useState(false);
  const [isSaving, setIsSaving] = useState(false);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    onEditingChange?.(isEditing);
  }, [isEditing, onEditingChange]);

  async function handleCopy() {
    if (!text) return;
    await navigator.clipboard.writeText(text);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1200);
  }

  function handleStartEdit() {
    setDraft(text);
    setIsEditing(true);
  }

  async function handleSave() {
    if (!editable || isSaving) return;
    if (draft === text) {
      setIsEditing(false);
      return;
    }

    setIsSaving(true);
    try {
      await onUpdateItem(item, draft);
      setIsEditing(false);
    } finally {
      setIsSaving(false);
    }
  }

  if (isEditing) {
    return (
      <div className="message-body message-body-editing">
        <textarea
          className="message-edit-input"
          value={draft}
          autoFocus
          disabled={isSaving}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Escape") setIsEditing(false);
            if ((event.metaKey || event.ctrlKey) && event.key === "Enter") handleSave();
          }}
        />
        <div className="message-actions message-edit-actions">
          <button className="message-action" type="button" onClick={handleSave} disabled={isSaving} aria-label="Save message edit" title="Save">
            <Check size={14} />
          </button>
          <button className="message-action" type="button" onClick={() => setIsEditing(false)} disabled={isSaving} aria-label="Cancel message edit" title="Cancel">
            <X size={14} />
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="message-body">
      <div className="message-text">{text}</div>
      <div className="message-actions">
        <button className="message-action" type="button" onClick={handleCopy} disabled={!text} aria-label="Copy message" title="Copy">
          <Copy size={13} />
        </button>
        {editable ? (
          <button className="message-action" type="button" onClick={handleStartEdit} aria-label="Edit message" title="Edit">
            <Pencil size={13} />
          </button>
        ) : null}
        {copied ? <span className="message-action-feedback">copied</span> : null}
      </div>
    </div>
  );
}

function ReferencePreviewList({ assetIds, assets }) {
  return (
    <div className="message-references">
      {assetIds.map((assetId) => {
        const asset = assets.find((candidate) => candidate.id === assetId);

        if (!asset) {
          return (
            <span className="message-reference missing" key={assetId}>
              <ImageIcon size={13} />
              Missing image
            </span>
          );
        }

        return (
          <span className="message-reference" key={asset.id}>
            <img alt="" src={previewUrl(asset)} />
            <span>{asset.file_name}</span>
          </span>
        );
      })}
    </div>
  );
}

function ToolRow({ item }) {
  const payload = item.payload || {};
  const codexItem = payload.codex_item || {};
  const status = item.status || "completed";
  const detail = truncate(JSON.stringify(codexItem, null, 2), 1400);

  return (
    <details className="tool-row">
      <summary>
        <TerminalSquare size={14} />
        <span className={`tool-status ${status}`}>{status}</span>
        <span className="tool-name">{payload.tool_name || toolName(codexItem) || "tool"}</span>
        <span className="tool-summary">{item.content || toolSummary(codexItem)}</span>
      </summary>
      {detail ? <pre>{detail}</pre> : null}
    </details>
  );
}

function ApprovalCard({ item, onRespond }) {
  const payload = item.payload || {};
  const action = payload.action || payload.event?.action || {};
  const review = payload.review || payload.event?.review || {};
  const status = item.status || review.status || "pending";
  const pending = status === "pending" || status === "inProgress";
  const detail = truncate(JSON.stringify(payload.event || payload.raw || {}, null, 2), 1400);

  return (
    <div className={`approval-card ${status}`}>
      <div className="approval-heading">
        <span className="approval-icon">
          <ShieldAlert size={15} />
        </span>
        <div>
          <strong>{approvalTitle(action)}</strong>
          <span>{approvalSubtitle(action)}</span>
        </div>
        <span className={`approval-status ${status}`}>{approvalStatusLabel(status)}</span>
      </div>

      {review.rationale ? <p>{review.rationale}</p> : null}

      <div className="approval-facts">
        {review.riskLevel ? <span>Risk {review.riskLevel}</span> : null}
        {payload.target_item_id ? <span>Target {String(payload.target_item_id).slice(0, 8)}</span> : null}
      </div>

      {pending ? (
        <div className="approval-actions">
          <button type="button" className="approval-button approve" onClick={() => onRespond?.(item, "approve")}>
            <Check size={14} />
            Approve
          </button>
          <button type="button" className="approval-button deny" onClick={() => onRespond?.(item, "deny")}>
            <X size={14} />
            Deny
          </button>
        </div>
      ) : null}

      {detail ? (
        <details className="approval-details">
          <summary>Payload</summary>
          <pre>{detail}</pre>
        </details>
      ) : null}
    </div>
  );
}

function groupTurns(items, activeRun, streamingText) {
  const groups = new Map();

  items.forEach((item) => {
    const id = item.turn_id || `item-${item.id}`;
    if (!groups.has(id)) {
      groups.set(id, {
        id,
        threadId: item.thread_id,
        status: item.turn_status || "completed",
        createdAt: item.turn_created_at || item.created_at,
        updatedAt: item.turn_updated_at || item.updated_at,
        error: item.turn_error,
        items: [],
        streamingText: "",
      });
    }

    const group = groups.get(id);
    group.status = activeRun?.turn_id === id ? "in_progress" : group.status;
    group.items.push(item);
  });

  if (activeRun?.turn_id) {
    if (!groups.has(activeRun.turn_id)) {
      groups.set(activeRun.turn_id, {
        id: activeRun.turn_id,
        threadId: activeRun.thread_id,
        status: "in_progress",
        createdAt: null,
        updatedAt: null,
        error: null,
        items: [],
        streamingText: "",
      });
    }

    const group = groups.get(activeRun.turn_id);
    group.status = activeRun.status === "waiting_approval" ? "waiting_approval" : "in_progress";
    group.streamingText = streamingText;
  }

  return Array.from(groups.values()).map((turn) => {
    const hasPendingApproval = turn.items.some((item) => item.type === "approval_request" && approvalPending(item));
    if (hasPendingApproval && turn.status !== "failed") return { ...turn, status: "waiting_approval" };
    return turn;
  });
}

function statusForThread(turns, agentRunning, currentThread, isDraftThread) {
  if (isDraftThread) return "draft";
  if (!currentThread) return "idle";
  if (agentRunning && turns.some((turn) => turn.status === "waiting_approval")) return "waiting";
  if (agentRunning) return "running";
  const latest = turns[turns.length - 1];
  if (latest?.status === "failed" || latest?.items?.some((item) => item.type === "error")) return "error";
  return "idle";
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

function toolName(item) {
  if (item.type === "commandExecution") return "command";
  if (item.type === "mcpToolCall") return [item.server, item.tool].filter(Boolean).join(" / ");
  if (item.type === "dynamicToolCall") return item.name;
  if (item.type === "webSearch") return "web search";
  if (item.type === "imageGeneration") return "image generation";
  if (item.type === "imageView") return "image view";
  return item.type;
}

function toolSummary(item) {
  return item.command || item.cmd || item.query || item.prompt || item.revisedPrompt || item.savedPath || item.path || "";
}

function approvalPending(item) {
  const status = item.status || item.payload?.review?.status;
  return status === "pending" || status === "inProgress";
}

function approvalTitle(action) {
  if (action.type === "command") return "Command approval";
  if (action.type === "execve") return "Program approval";
  if (action.type === "applyPatch") return "Patch approval";
  if (action.type === "networkAccess") return "Network approval";
  if (action.type === "mcpToolCall") return "MCP approval";
  if (action.type === "requestPermissions") return "Permission approval";
  return "Approval request";
}

function approvalSubtitle(action) {
  if (action.type === "command") return action.command || "";
  if (action.type === "execve") return [action.program, ...(action.argv || [])].filter(Boolean).join(" ");
  if (action.type === "applyPatch") return (action.files || []).join(", ");
  if (action.type === "networkAccess") return [action.protocol, action.target || action.host, action.port].filter(Boolean).join(" ");
  if (action.type === "mcpToolCall") return [action.server, action.toolTitle || action.toolName].filter(Boolean).join(" / ");
  if (action.type === "requestPermissions") return action.reason || "";
  return "";
}

function approvalStatusLabel(status) {
  if (status === "pending" || status === "inProgress") return "waiting";
  if (status === "timedOut") return "timed out";
  return status;
}

function shortTurnId(id) {
  if (!id) return "turn";
  return `turn ${String(id).slice(0, 8)}`;
}

function formatTime(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function truncate(value, maxLength) {
  if (!value || value === "{}") return "";
  return value.length > maxLength ? `${value.slice(0, maxLength)}...` : value;
}
