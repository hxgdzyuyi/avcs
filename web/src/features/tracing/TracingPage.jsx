import { useEffect, useMemo, useRef, useState } from "react";
import { ArrowLeft, Check, Copy, RefreshCcw, TerminalSquare, Workflow } from "lucide-react";
import IconButton from "../../components/IconButton.jsx";
import { Compartment, EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { defaultHighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";

export default function TracingPage({
  channel,
  connectionState,
  project,
  threadId,
  threads = [],
  onBack,
}) {
  const [items, setItems] = useTracingItems(channel, project, threadId);
  const turns = useMemo(() => groupTracingTurns(items.data), [items.data]);
  const [selectedTurnId, setSelectedTurnId] = useStableTurnSelection(turns);
  const [selectedItemId, setSelectedItemId] = useState(null);
  const [selectedItemAnchorTick, setSelectedItemAnchorTick] = useState(0);
  const selectedTurn = turns.find((turn) => turn.id === selectedTurnId) || null;
  const thread = threads.find((entry) => entry.id === threadId);
  const canLoad = Boolean(channel && project && threadId);

  async function refreshTracing() {
    if (!canLoad) return;
    setItems({ status: "loading", error: "", data: items.data });

    try {
      const data = await channel.push("thread:items:list", { thread_id: threadId });
      setItems({ status: "loaded", error: "", data: data.items || [] });
    } catch (error) {
      setItems({ status: "error", error: error.message, data: items.data });
    }
  }

  useEffect(() => {
    if (!selectedItemId || !selectedItemAnchorTick || !selectedTurnId) return;

    const hasSelectedItem = turns.some(
      (turn) => turn.id === selectedTurnId && turn.items.some((item) => item.id === selectedItemId),
    );
    if (!hasSelectedItem) return;

    window.requestAnimationFrame(() => {
      const target = document.getElementById(`tracing-item-${selectedItemId}`);
      target?.scrollIntoView({
        block: "center",
        inline: "center",
        behavior: "smooth",
      });
    });
  }, [selectedItemId, selectedItemAnchorTick, selectedTurnId, turns]);

  return (
    <main className="tracing-page">
      <header className="tracing-header">
        <IconButton label="Back to workspace" onClick={onBack}>
          <ArrowLeft size={17} />
        </IconButton>
        <div className="tracing-title">
          <span className="eyebrow">Tracing</span>
          <h1 title={thread?.title || threadId}>{thread?.title || `Thread ${shortId(threadId)}`}</h1>
        </div>
        <div className="tracing-header-actions">
          <span className={`connection-dot ${connectionState}`} title={connectionState} />
          <IconButton label="Refresh tracing" onClick={refreshTracing} disabled={!canLoad || items.status === "loading"}>
            <RefreshCcw size={16} />
          </IconButton>
        </div>
      </header>

      <div className="tracing-shell">
        <aside className="tracing-tree-pane">
          <div className="tracing-pane-heading">
            <Workflow size={16} />
            <strong>Turns</strong>
            <span>{turns.length}</span>
          </div>
          <TracingTree
            status={items.status}
            error={items.error}
            project={project}
            turns={turns}
            selectedTurnId={selectedTurnId}
            onSelectTurn={(turnId) => {
              setSelectedTurnId(turnId);
              setSelectedItemId(null);
              setSelectedItemAnchorTick(0);
            }}
            onSelectItem={(turnId, itemId) => {
              setSelectedTurnId(turnId);
              setSelectedItemId(itemId);
              setSelectedItemAnchorTick((current) => current + 1);
            }}
          />
        </aside>

        <section className="tracing-detail-pane">
          {selectedTurn ? (
            <TurnDetail turn={selectedTurn} selectedItemId={selectedItemId} />
          ) : (
            <div className="tracing-empty">
              <TerminalSquare size={20} />
              <strong>No turn selected</strong>
              <span>{emptyDetailMessage(items.status, project)}</span>
            </div>
          )}
        </section>
      </div>
    </main>
  );
}

function useTracingItems(channel, project, threadId) {
  const [items, setItems] = useState({ status: "idle", error: "", data: [] });

  useEffect(() => {
    if (!threadId) {
      setItems({ status: "idle", error: "", data: [] });
      return undefined;
    }

    if (!channel || !project) {
      setItems({ status: channel ? "idle" : "loading", error: "", data: [] });
      return undefined;
    }

    let cancelled = false;
    setItems({ status: "loading", error: "", data: [] });

    channel
      .push("thread:items:list", { thread_id: threadId })
      .then((data) => {
        if (!cancelled) setItems({ status: "loaded", error: "", data: data.items || [] });
      })
      .catch((error) => {
        if (!cancelled) setItems({ status: "error", error: error.message, data: [] });
      });

    return () => {
      cancelled = true;
    };
  }, [channel, project, threadId]);

  return [items, setItems];
}

function useStableTurnSelection(turns) {
  const [selectedTurnId, setSelectedTurnId] = useState(null);

  useEffect(() => {
    if (turns.length === 0) {
      setSelectedTurnId(null);
      return;
    }

    if (!turns.some((turn) => turn.id === selectedTurnId)) {
      setSelectedTurnId(turns[0].id);
    }
  }, [selectedTurnId, turns]);

  return [selectedTurnId, setSelectedTurnId];
}

function TracingTree({ status, error, project, turns, selectedTurnId, onSelectTurn, onSelectItem }) {
  if (!project) {
    return <div className="tracing-tree-empty">Open a project to view tracing.</div>;
  }

  if (status === "loading") {
    return <div className="tracing-tree-empty">Loading tracing...</div>;
  }

  if (status === "error") {
    return <div className="tracing-tree-empty error">{error || "Tracing load failed."}</div>;
  }

  if (turns.length === 0) {
    return <div className="tracing-tree-empty">No turns found for this thread.</div>;
  }

  return (
    <div className="tracing-tree">
      {turns.map((turn, index) => (
        <div className="tracing-turn-node" key={turn.id}>
          <button
            className={turn.id === selectedTurnId ? "selected" : ""}
            type="button"
            onClick={() => onSelectTurn(turn.id)}
          >
            <span className="tracing-node-index">{index + 1}</span>
            <span className="tracing-node-main">
              <strong>{turnLabel(turn, index)}</strong>
              <small>{formatTime(turn.createdAt)} · {turn.items.length} items</small>
            </span>
            <span className={`turn-status ${turn.status}`}>{turn.status}</span>
          </button>

          <div className="tracing-item-list">
            {turn.items.map((item) => (
              <button
                type="button"
                key={item.id}
                onClick={() => onSelectItem?.(turn.id, item.id)}
              >
                <span className={`tracing-item-dot ${item.status || "completed"}`} />
                <span>{item.type || "item"}</span>
                <small>{item.role || item.status || "item"}</small>
              </button>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

function TurnDetail({ turn, selectedItemId }) {
  return (
    <div className="tracing-detail">
      <header className="tracing-detail-header">
        <div>
          <span className="eyebrow">Turn Detail</span>
          <h2 title={turn.id}>{turnLabel(turn)}</h2>
        </div>
        <span className={`turn-status ${turn.status}`}>{turn.status}</span>
      </header>

      <section className="tracing-facts">
        <Fact label="Turn ID" value={turn.id} />
        <Fact label="Thread ID" value={turn.threadId} />
        <Fact label="Created" value={formatTime(turn.createdAt)} />
        <Fact label="Updated" value={formatTime(turn.updatedAt)} />
        <Fact label="Completed" value={formatTime(turn.completedAt)} />
        <Fact label="Model" value={turn.model || "default"} />
        <Fact label="Effort" value={turn.effort || "default"} />
        <Fact label="Approval" value={turn.approvalPolicy || "default"} />
        <Fact label="Access" value={turn.sandboxMode || "default"} />
      </section>

      {turn.userText ? (
        <section className="tracing-section">
          <h3>User Text</h3>
          <pre>{turn.userText}</pre>
        </section>
      ) : null}

      {turn.error ? (
        <section className="tracing-section error">
          <h3>Error</h3>
          <pre>{turn.error}</pre>
        </section>
      ) : null}

      <section className="tracing-section">
        <h3>Items</h3>
          <div className="tracing-detail-items">
          {turn.items.map((item, index) => {
            const output = aggregatedOutputForItem(item);
            const commandActions = commandActionsForItem(item);
            const isSelected = item.id === selectedItemId;

            return (
              <article
                className={`tracing-detail-item${isSelected ? " selected" : ""}`}
                id={`tracing-item-${item.id}`}
                key={item.id}
              >
                <header>
                  <span>{index + 1}</span>
                  <strong>{item.type || "item"}</strong>
                  <small>{[item.role, item.status].filter(Boolean).join(" · ")}</small>
                </header>
                <dl>
                  <DetailField label="ID" value={item.id} />
                  <DetailField label="Codex Item" value={item.codex_item_id} />
                  <DetailField label="Created" value={formatTime(item.created_at)} />
                  <DetailField label="Updated" value={formatTime(item.updated_at)} />
                </dl>
              {commandActions.map((action, actionIndex) => (
                <TextBlock
                  key={`${actionIndex}-${action.command}`}
                  label={commandActionLabel(action, actionIndex, commandActions.length)}
                  meta={action.type || "command"}
                  value={action.command}
                  variant="command"
                />
              ))}
                {output ? <TextBlock label="Aggregated Output" value={output} /> : null}
                {item.content && item.content !== output ? (
                  <CodeBlockRenderer
                    value={item.content}
                    language={itemContentLanguage(item)}
                    maxHeight={360}
                    className="tracing-detail-item-content"
                  />
                ) : null}
                {hasPayload(item.payload) ? <JsonBlock label="Payload" value={item.payload} /> : null}
              </article>
            );
          })}
        </div>
      </section>
    </div>
  );
}

function Fact({ label, value }) {
  return (
    <div>
      <span>{label}</span>
      <strong title={value || "-"}>{value || "-"}</strong>
    </div>
  );
}

function DetailField({ label, value }) {
  if (!value) return null;

  return (
    <>
      <dt>{label}</dt>
      <dd title={value}>{value}</dd>
    </>
  );
}

function JsonBlock({ label, value }) {
  return (
    <details className="tracing-json" open>
      <summary>{label}</summary>
      <CodeBlockRenderer
        value={JSON.stringify(value, null, 2)}
        language="json"
        className="tracing-json-code"
      />
    </details>
  );
}

function TextBlock({ label, meta, value, variant = "output" }) {
  const [copied, setCopied] = useState(false);

  async function copyText() {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1200);
    } catch (_error) {
      setCopied(false);
    }
  }

  return (
    <section className={`tracing-output ${variant}`}>
      <header>
        <strong>{label}</strong>
        <span>{meta ? `${meta} · ` : ""}{lineCount(value)} lines</span>
        <IconButton label={`Copy ${label.toLowerCase()}`} onClick={copyText}>
          {copied ? <Check size={14} /> : <Copy size={14} />}
        </IconButton>
      </header>
      {variant === "output" ? (
        <MarkdownPreview value={value} />
      ) : (
        <CodeBlockRenderer
          value={value}
          language="javascript"
          className="tracing-output-command"
        />
      )}
    </section>
  );
}

function MarkdownPreview({ value }) {
  const blocks = useMemo(() => parseMarkdownBlocks(value), [value]);

  return (
    <div className="tracing-markdown">
      {blocks.map((block, index) => renderMarkdownBlock(block, index))}
    </div>
  );
}

function renderMarkdownBlock(block, index) {
  if (block.type === "heading") {
    const Tag = `h${Math.min(block.level + 2, 5)}`;
    return <Tag key={index}>{renderInlineMarkdown(block.text)}</Tag>;
  }

  if (block.type === "list") {
    const ListTag = block.ordered ? "ol" : "ul";
    return (
      <ListTag key={index}>
        {block.items.map((item, itemIndex) => (
          <li key={itemIndex}>{renderInlineMarkdown(item)}</li>
        ))}
      </ListTag>
    );
  }

  if (block.type === "quote") {
    return <blockquote key={index}>{renderInlineMarkdown(block.text)}</blockquote>;
  }

  if (block.type === "code") {
    return (
      <div className="tracing-md-code" key={index}>
        {block.language ? <span>{block.language}</span> : null}
        <CodeBlockRenderer value={block.text} language={block.language} maxHeight={320} />
      </div>
    );
  }

  return <p key={index}>{renderInlineMarkdown(block.text)}</p>;
}

function parseMarkdownBlocks(value) {
  const blocks = [];
  const lines = String(value || "").split("\n");
  let paragraph = [];
  let list = null;
  let code = null;

  function flushParagraph() {
    if (paragraph.length === 0) return;
    blocks.push({ type: "paragraph", text: paragraph.join("\n") });
    paragraph = [];
  }

  function flushList() {
    if (!list) return;
    blocks.push(list);
    list = null;
  }

  lines.forEach((line) => {
    const fence = line.match(/^```(\S*)\s*$/);

    if (code) {
      if (fence) {
        blocks.push({ type: "code", language: code.language, text: code.lines.join("\n") });
        code = null;
      } else {
        code.lines.push(line);
      }
      return;
    }

      if (fence) {
        flushParagraph();
        flushList();
        code = { language: (fence[1] || "").trim(), lines: [] };
        return;
      }

    if (!line.trim()) {
      flushParagraph();
      flushList();
      return;
    }

    const heading = line.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      flushParagraph();
      flushList();
      blocks.push({ type: "heading", level: heading[1].length, text: heading[2] });
      return;
    }

    const quote = line.match(/^>\s?(.*)$/);
    if (quote) {
      flushParagraph();
      flushList();
      blocks.push({ type: "quote", text: quote[1] });
      return;
    }

    const unordered = line.match(/^\s*[-*]\s+(.+)$/);
    const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
    if (unordered || ordered) {
      flushParagraph();
      const orderedList = Boolean(ordered);
      if (!list || list.ordered !== orderedList) {
        flushList();
        list = { type: "list", ordered: orderedList, items: [] };
      }
      list.items.push((ordered || unordered)[1]);
      return;
    }

    flushList();
    paragraph.push(line);
  });

  if (code) {
    blocks.push({ type: "code", language: code.language, text: code.lines.join("\n") });
  }
  flushParagraph();
  flushList();
  return blocks.length > 0 ? blocks : [{ type: "paragraph", text: "" }];
}

function CodeBlockRenderer({
  value,
  language,
  className = "",
  maxHeight = 420,
}) {
  const hostRef = useRef(null);
  const viewRef = useRef(null);
  const languageCompartment = useRef(new Compartment());
  const currentLanguage = useRef("");
  const [renderError, setRenderError] = useState(false);

  const content = useMemo(() => String(value || ""), [value]);
  const languageTag = useMemo(() => resolveCodeLanguageTag(language), [language]);

  useEffect(() => {
    if (!hostRef.current || renderError) return;

    try {
      const view = new EditorView({
        parent: hostRef.current,
        state: EditorState.create({
          doc: content,
          extensions: [
            syntaxHighlighting(defaultHighlightStyle),
            EditorView.lineWrapping,
            EditorView.editable.of(false),
            EditorState.readOnly.of(true),
            languageCompartment.current.of(resolveCodeLanguageExtension(languageTag)),
          ],
        }),
      });
      viewRef.current = view;
      currentLanguage.current = languageTag;

      return () => {
        view.destroy();
        viewRef.current = null;
      };
    } catch (_error) {
      setRenderError(true);
      return undefined;
    }
  }, []);

  useEffect(() => {
    const view = viewRef.current;
    if (!view || renderError) return;

    if (view.state.doc.toString() !== content) {
      view.dispatch({
        changes: { from: 0, to: view.state.doc.length, insert: content },
      });
    }

    if (currentLanguage.current !== languageTag) {
      view.dispatch({
        effects: languageCompartment.current.reconfigure(resolveCodeLanguageExtension(languageTag)),
      });
      currentLanguage.current = languageTag;
    }
  }, [content, languageTag, renderError]);

  if (renderError) {
    return (
      <pre className={`tracing-code-block-fallback ${className}`.trim()} style={{ maxHeight: `${maxHeight}px` }}>
        {content}
      </pre>
    );
  }

  return (
    <div
      ref={hostRef}
      className={`tracing-code-block ${className}`.trim()}
      style={{ "--tracing-code-block-max-height": `${maxHeight}px` }}
    />
  );
}

function resolveCodeLanguageTag(language) {
  const normalized = String(language || "").toLowerCase().trim();
  if (!normalized) return "";

  const tokens = [
    ...new Set(
      normalized
        .split(/[^a-z0-9+.#-]+/g)
        .flatMap((piece) => piece.split(/[._-]/g))
        .map((token) => token.toLowerCase().trim())
        .filter(Boolean),
    ),
  ];

  if (tokens.includes("json")) return "json";

  const javascriptTokens = new Set(["js", "javascript", "jsx", "ts", "tsx", "typescript", "babel", "node"]);
  if (tokens.some((token) => javascriptTokens.has(token))) return "javascript";

  if (tokens.includes("md") || tokens.includes("markdown")) return "markdown";

  const shellTokens = new Set(["bash", "sh", "shell", "zsh", "powershell", "pwsh", "cmd", "command", "terminal"]);
  if (tokens.some((token) => shellTokens.has(token))) return "javascript";

  return "";
}

function resolveCodeLanguageExtension(languageTag) {
  if (languageTag === "json") return json();
  if (languageTag === "javascript") return javascript();
  if (languageTag === "markdown") return markdown();
  return [];
}

function itemContentLanguage(item) {
  return [
    item.type || "",
    item.role || "",
    item.status || "",
    item?.payload?.codex_item?.type || "",
    item?.payload?.codex_item?.name || "",
    item?.payload?.codex_item?.command_type || "",
  ]
    .filter(Boolean)
    .join(" ");
}

function renderInlineMarkdown(text) {
  return String(text || "")
    .split(/(`[^`]+`)/g)
    .flatMap((part, index) => {
      if (part.startsWith("`") && part.endsWith("`")) {
        return [<code key={`code-${index}`}>{part.slice(1, -1)}</code>];
      }

      return renderStrongMarkdown(part, index);
    });
}

function renderStrongMarkdown(text, parentIndex) {
  return String(text || "")
    .split(/(\*\*[^*]+\*\*)/g)
    .map((part, index) => {
      if (part.startsWith("**") && part.endsWith("**")) {
        return <strong key={`strong-${parentIndex}-${index}`}>{part.slice(2, -2)}</strong>;
      }

      return part;
    });
}

function groupTracingTurns(items) {
  const groups = new Map();

  items.forEach((item) => {
    const id = item.turn_id || `item-${item.id}`;
    if (!groups.has(id)) {
      groups.set(id, {
        id,
        threadId: item.thread_id,
        status: item.turn_status || item.status || "completed",
        userText: item.turn_user_text || "",
        model: item.turn_model || "",
        effort: item.turn_effort || "",
        approvalPolicy: item.turn_approval_policy || "",
        sandboxMode: item.turn_sandbox_mode || "",
        createdAt: item.turn_created_at || item.created_at,
        updatedAt: item.turn_updated_at || item.updated_at,
        completedAt: item.turn_completed_at || "",
        error: item.turn_error || "",
        items: [],
      });
    }

    groups.get(id).items.push(item);
  });

  return Array.from(groups.values());
}

function turnLabel(turn, index = null) {
  const prefix = index === null ? "Turn" : `Turn ${index + 1}`;
  if (turn.userText) return `${prefix}: ${truncateLine(turn.userText, 64)}`;
  return `${prefix} ${shortId(turn.id)}`;
}

function shortId(id) {
  return id ? String(id).slice(0, 8) : "-";
}

function truncateLine(value, maxLength) {
  const clean = String(value).replace(/\s+/g, " ").trim();
  return clean.length > maxLength ? `${clean.slice(0, maxLength - 1)}...` : clean;
}

function formatTime(value) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString([], {
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function hasPayload(payload) {
  return Boolean(payload && typeof payload === "object" && Object.keys(payload).length > 0);
}

function aggregatedOutputForItem(item) {
  const output = item?.payload?.codex_item?.aggregatedOutput;
  return typeof output === "string" && output.length > 0 ? output : "";
}

function commandActionsForItem(item) {
  const actions = item?.payload?.codex_item?.commandActions;
  if (!Array.isArray(actions)) return [];

  return actions.flatMap((action) => {
    if (typeof action === "string" && action.length > 0) {
      return [{ command: action, type: "" }];
    }

    if (typeof action?.command === "string" && action.command.length > 0) {
      return [{ command: action.command, type: action.type || "" }];
    }

    return [];
  });
}

function commandActionLabel(_action, index, total) {
  return total > 1 ? `Command Action ${index + 1}` : "Command Action";
}

function lineCount(value) {
  if (!value) return 0;
  return value.split("\n").length;
}

function emptyDetailMessage(status, project) {
  if (!project) return "No project is selected.";
  if (status === "loading") return "Tracing is loading.";
  if (status === "error") return "Tracing could not be loaded.";
  return "Select a turn in the tree.";
}
