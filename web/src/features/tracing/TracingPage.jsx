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
  const [traceEvents, setTraceEvents] = useTraceEvents(channel, project, threadId);
  const [activeView, setActiveView] = useState("timeline");
  const [filters, setFilters] = useState({
    query: "",
    scope: "",
    status: "",
    eventName: "",
  });
  const events = useMemo(() => normalizeTraceEvents(traceEvents.data), [traceEvents.data]);
  const filteredEvents = useMemo(() => filterTraceEvents(events, filters), [events, filters]);
  const timelineGroups = useMemo(() => groupTimelineEvents(filteredEvents, threadId), [filteredEvents, threadId]);
  const filterOptions = useMemo(() => traceFilterOptions(events), [events]);
  const [selectedTimelineKey, setSelectedTimelineKey] = useStableTimelineSelection(timelineGroups);
  const selectedTimelineEvent = selectedTimelineKey?.startsWith("event:")
    ? filteredEvents.find((event) => timelineEventKey(event) === selectedTimelineKey) || null
    : null;
  const selectedTimelineGroup = selectedTimelineEvent
    ? timelineGroups.find((group) => group.events.some((event) => event._rowKey === selectedTimelineEvent._rowKey)) || null
    : timelineGroups.find((group) => timelineGroupKey(group) === selectedTimelineKey) || null;
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
    setTraceEvents({ status: "loading", error: "", data: traceEvents.data });

    try {
      const [itemData, eventData] = await Promise.all([
        channel.push("thread:items:list", { thread_id: threadId }),
        channel.push("trace:events:list", { thread_id: threadId }),
      ]);
      setItems({ status: "loaded", error: "", data: itemData.items || [] });
      setTraceEvents({ status: "loaded", error: "", data: eventData.items || [] });
    } catch (error) {
      setItems({ status: "error", error: error.message, data: items.data });
      setTraceEvents({ status: "error", error: error.message, data: traceEvents.data });
    }
  }

  useEffect(() => {
    if (activeView !== "snapshot" || !selectedItemId || !selectedItemAnchorTick || !selectedTurnId) return;

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
  }, [activeView, selectedItemId, selectedItemAnchorTick, selectedTurnId, turns]);

  useEffect(() => {
    if (activeView !== "timeline" || !selectedTimelineKey) return;

    window.requestAnimationFrame(() => {
      const target = document.getElementById(`tracing-node-${selectedTimelineKey}`);
      target?.scrollIntoView({
        block: "center",
        inline: "center",
        behavior: "smooth",
      });
    });
  }, [activeView, selectedTimelineKey]);

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
          <div className="segmented tracing-mode-switch" role="tablist" aria-label="Tracing view">
            <button
              className={activeView === "timeline" ? "active" : ""}
              type="button"
              role="tab"
              aria-selected={activeView === "timeline"}
              onClick={() => setActiveView("timeline")}
            >
              Timeline
            </button>
            <button
              className={activeView === "snapshot" ? "active" : ""}
              type="button"
              role="tab"
              aria-selected={activeView === "snapshot"}
              onClick={() => setActiveView("snapshot")}
            >
              Snapshot
            </button>
          </div>
          <span className={`connection-dot ${connectionState}`} title={connectionState} />
          <IconButton
            label="Refresh tracing"
            onClick={refreshTracing}
            disabled={!canLoad || items.status === "loading" || traceEvents.status === "loading"}
          >
            <RefreshCcw size={16} />
          </IconButton>
        </div>
      </header>

      <div className="tracing-shell">
        {activeView === "timeline" ? (
          <TimelineView
            status={traceEvents.status}
            error={traceEvents.error}
            project={project}
            groups={timelineGroups}
            totalEvents={events.length}
            filteredCount={filteredEvents.length}
            filters={filters}
            filterOptions={filterOptions}
            selectedTimelineKey={selectedTimelineKey}
            selectedEvent={selectedTimelineEvent}
            selectedGroup={selectedTimelineGroup}
            onFiltersChange={setFilters}
            onSelectTimeline={setSelectedTimelineKey}
          />
        ) : (
          <SnapshotView
            status={items.status}
            error={items.error}
            project={project}
            turns={turns}
            selectedTurnId={selectedTurnId}
            selectedTurn={selectedTurn}
            selectedItemId={selectedItemId}
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
        )}
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

function useTraceEvents(channel, project, threadId) {
  const [events, setEvents] = useState({ status: "idle", error: "", data: [] });

  useEffect(() => {
    if (!threadId) {
      setEvents({ status: "idle", error: "", data: [] });
      return undefined;
    }

    if (!channel || !project) {
      setEvents({ status: channel ? "idle" : "loading", error: "", data: [] });
      return undefined;
    }

    let cancelled = false;
    setEvents({ status: "loading", error: "", data: [] });

    channel
      .push("trace:events:list", { thread_id: threadId })
      .then((data) => {
        if (!cancelled) setEvents({ status: "loaded", error: "", data: data.items || [] });
      })
      .catch((error) => {
        if (!cancelled) setEvents({ status: "error", error: error.message, data: [] });
      });

    return () => {
      cancelled = true;
    };
  }, [channel, project, threadId]);

  return [events, setEvents];
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

function useStableTimelineSelection(groups) {
  const [selectedTimelineKey, setSelectedTimelineKey] = useState(null);

  useEffect(() => {
    if (groups.length === 0) {
      setSelectedTimelineKey(null);
      return;
    }

    if (!timelineSelectionExists(groups, selectedTimelineKey)) {
      setSelectedTimelineKey(timelineGroupKey(groups[0]));
    }
  }, [selectedTimelineKey, groups]);

  return [selectedTimelineKey, setSelectedTimelineKey];
}

function TimelineView({
  status,
  error,
  project,
  groups,
  totalEvents,
  filteredCount,
  filters,
  filterOptions,
  selectedTimelineKey,
  selectedEvent,
  selectedGroup,
  onFiltersChange,
  onSelectTimeline,
}) {
  return (
    <>
      <aside className="tracing-tree-pane">
        <div className="tracing-pane-heading">
          <Workflow size={16} />
          <strong>Events</strong>
          <span>{filteredCount}/{totalEvents}</span>
        </div>
        <TracingFilters
          filters={filters}
          options={filterOptions}
          disabled={!project || status === "loading"}
          onChange={onFiltersChange}
        />
        <TimelineTree
          status={status}
          error={error}
          project={project}
          groups={groups}
          totalEvents={totalEvents}
          selectedTimelineKey={selectedTimelineKey}
          onSelectTimeline={onSelectTimeline}
        />
      </aside>

      <section className="tracing-detail-pane">
        {selectedTimelineKey?.startsWith("group:") && selectedGroup ? (
          <TimelineGroupDetail group={selectedGroup} />
        ) : selectedEvent ? (
          <EventDetail event={selectedEvent} />
        ) : (
          <div className="tracing-empty">
            <TerminalSquare size={20} />
            <strong>No event selected</strong>
            <span>{emptyEventDetailMessage(status, project, totalEvents)}</span>
          </div>
        )}
      </section>
    </>
  );
}

function SnapshotView({
  status,
  error,
  project,
  turns,
  selectedTurnId,
  selectedTurn,
  selectedItemId,
  onSelectTurn,
  onSelectItem,
}) {
  return (
    <>
      <aside className="tracing-tree-pane">
        <div className="tracing-pane-heading">
          <Workflow size={16} />
          <strong>Turns</strong>
          <span>{turns.length}</span>
        </div>
        <TracingTree
          status={status}
          error={error}
          project={project}
          turns={turns}
          selectedTurnId={selectedTurnId}
          onSelectTurn={onSelectTurn}
          onSelectItem={onSelectItem}
        />
      </aside>

      <section className="tracing-detail-pane">
        {selectedTurn ? (
          <TurnDetail turn={selectedTurn} selectedItemId={selectedItemId} />
        ) : (
          <div className="tracing-empty">
            <TerminalSquare size={20} />
            <strong>No turn selected</strong>
            <span>{emptyDetailMessage(status, project)}</span>
          </div>
        )}
      </section>
    </>
  );
}

function TracingFilters({ filters, options, disabled, onChange }) {
  const hasFilters = Boolean(filters.query || filters.scope || filters.status || filters.eventName);
  const hasCodexRpcScope = options.scopes.includes("codex_rpc");

  function setFilter(key, value) {
    onChange((current) => ({ ...current, [key]: value }));
  }

  function clearFilters() {
    onChange({
      query: "",
      scope: "",
      status: "",
      eventName: "",
    });
  }

  return (
    <div className="tracing-filters" aria-label="Trace event filters">
      <label>
        <span>Search</span>
        <input
          type="search"
          value={filters.query}
          placeholder="IDs, event, JSON"
          disabled={disabled}
          onChange={(event) => setFilter("query", event.target.value)}
        />
      </label>
      <label>
        <span>Scope</span>
        <select
          value={filters.scope}
          disabled={disabled}
          onChange={(event) => setFilter("scope", event.target.value)}
        >
          <option value="">All scopes</option>
          {options.scopes.map((scope) => (
            <option value={scope} key={scope}>{scope}</option>
          ))}
        </select>
      </label>
      <label>
        <span>Status</span>
        <select
          value={filters.status}
          disabled={disabled}
          onChange={(event) => setFilter("status", event.target.value)}
        >
          <option value="">All statuses</option>
          {options.statuses.map((status) => (
            <option value={status} key={status}>{status}</option>
          ))}
        </select>
      </label>
      <label>
        <span>Event</span>
        <input
          type="search"
          value={filters.eventName}
          placeholder="event_name"
          disabled={disabled}
          onChange={(event) => setFilter("eventName", event.target.value)}
        />
      </label>
      <button type="button" className="tracing-filter-reset" disabled={disabled || !hasFilters} onClick={clearFilters}>
        Reset
      </button>
      {hasCodexRpcScope ? (
        <button
          type="button"
          className={`tracing-filter-reset${filters.scope === "codex_rpc" ? " active" : ""}`}
          disabled={disabled}
          onClick={() => setFilter("scope", filters.scope === "codex_rpc" ? "" : "codex_rpc")}
        >
          Codex RPC
        </button>
      ) : null}
    </div>
  );
}

function TimelineTree({ status, error, project, groups, totalEvents, selectedTimelineKey, onSelectTimeline }) {
  if (!project) {
    return <div className="tracing-tree-empty">Open a project to view tracing.</div>;
  }

  if (status === "loading") {
    return <div className="tracing-tree-empty">Loading trace events...</div>;
  }

  if (status === "error") {
    return <div className="tracing-tree-empty error">{error || "Trace events load failed."}</div>;
  }

  if (totalEvents === 0) {
    return <div className="tracing-tree-empty">No trace events found for this thread.</div>;
  }

  if (groups.length === 0) {
    return <div className="tracing-tree-empty">No trace events match the current filters.</div>;
  }

  const threadGroups = groups.filter((group) => group.type === "thread");
  const turnGroups = groups.filter((group) => group.type !== "thread");

  return (
    <div className="tracing-tree">
      {threadGroups.length > 0 ? (
        <div className="tracing-tree-section">
          <div className="tracing-tree-section-title">Thread</div>
          {threadGroups.map((group) => (
            <TimelineGroupNode
              key={group.id}
              group={group}
              selectedTimelineKey={selectedTimelineKey}
              onSelectTimeline={onSelectTimeline}
            />
          ))}
        </div>
      ) : null}

      {turnGroups.length > 0 ? (
        <div className="tracing-tree-section">
          <div className="tracing-tree-section-title">Turns</div>
          {turnGroups.map((group, index) => (
            <TimelineGroupNode
              key={group.id}
              group={group}
              index={index}
              selectedTimelineKey={selectedTimelineKey}
              onSelectTimeline={onSelectTimeline}
            />
          ))}
        </div>
      ) : null}
    </div>
  );
}

function TimelineGroupNode({ group, index = null, selectedTimelineKey, onSelectTimeline }) {
  const groupKey = timelineGroupKey(group);
  const selectedInGroup = selectedTimelineKey === groupKey ||
    group.events.some((event) => timelineEventKey(event) === selectedTimelineKey);

  return (
    <div className="tracing-turn-node tracing-event-group">
      <button
        id={`tracing-node-${groupKey}`}
        className={selectedInGroup ? "selected" : ""}
        type="button"
        onClick={() => onSelectTimeline(groupKey)}
      >
        <span className="tracing-node-index">{timelineGroupIndexLabel(group, index)}</span>
        <span className="tracing-node-main">
          <strong>{timelineGroupLabel(group, index)}</strong>
          <small>{formatTime(group.createdAt)} · {group.events.length} events</small>
        </span>
        <span className={`turn-status ${group.status || ""}`}>{group.status || group.type}</span>
      </button>

      <div className="tracing-item-list tracing-event-item-list">
        {group.events.map((event) => {
          const eventKey = timelineEventKey(event);

          return (
            <button
              type="button"
              id={`tracing-node-${eventKey}`}
              key={event._rowKey}
              className={eventKey === selectedTimelineKey ? "selected" : ""}
              onClick={() => onSelectTimeline(eventKey)}
            >
              <span className={`tracing-item-dot ${event.status || "completed"}`} />
              <span>{event.event_name || "event"}</span>
              <small>{traceEventSubtitle(event)}</small>
            </button>
          );
        })}
      </div>
    </div>
  );
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

function TimelineGroupDetail({ group }) {
  const [copied, setCopied] = useState(false);
  const markdown = useMemo(() => timelineGroupMarkdown(group), [group]);
  const lastEvent = group.events[group.events.length - 1] || null;

  async function copyMarkdown() {
    try {
      await navigator.clipboard.writeText(markdown);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1200);
    } catch (_error) {
      setCopied(false);
    }
  }

  return (
    <div className="tracing-detail">
      <header className="tracing-detail-header">
        <div>
          <span className="eyebrow">{group.type === "thread" ? "Thread Events" : "Turn Events"}</span>
          <h2 title={group.turnId || group.threadId}>{timelineGroupLabel(group)}</h2>
        </div>
        <div className="tracing-detail-actions">
          <span className={`turn-status ${group.status || ""}`}>{group.status || group.type}</span>
          <IconButton label="Copy turn changes as Markdown" onClick={copyMarkdown}>
            {copied ? <Check size={14} /> : <Copy size={14} />}
          </IconButton>
        </div>
      </header>

      <section className="tracing-facts">
        <Fact label="Thread ID" value={group.threadId} />
        <Fact label="Turn ID" value={group.turnId} />
        <Fact label="Events" value={group.events.length} />
        <Fact label="First Event" value={formatTime(group.createdAt)} />
        <Fact label="Last Event" value={formatTime(lastEvent?.created_at)} />
        <Fact label="Status" value={group.status} />
      </section>

      <EventTimeline
        title={group.type === "thread" ? "Thread Events" : "Turn Events"}
        events={group.events}
        emptyLabel="No trace events recorded for this group."
      />
    </div>
  );
}

function EventDetail({ event }) {
  const eventRow = publicEventRow(event);

  return (
    <div className="tracing-detail">
      <header className="tracing-detail-header">
        <div>
          <span className="eyebrow">Trace Event</span>
          <h2 title={event.event_name || event.id}>{event.event_name || "Trace event"}</h2>
        </div>
        <span className={`turn-status ${event.status || ""}`}>{event.status || "event"}</span>
      </header>

      <section className="tracing-facts">
        <Fact label="Event ID" value={event.id} />
        <Fact label="Scope" value={event.scope} />
        {event.scope === "codex_rpc" ? (
          <>
            <Fact label="RPC Method" value={codexRpcPayloadValue(event, "method")} />
            <Fact label="Direction" value={codexRpcPayloadValue(event, "direction")} />
            <Fact label="RPC ID" value={codexRpcPayloadValue(event, "rpc_id")} />
          </>
        ) : null}
        <Fact label="Thread ID" value={event.thread_id} />
        <Fact label="Turn ID" value={event.turn_id} />
        <Fact label="Item ID" value={event.item_id} />
        <Fact label="Created" value={formatTime(event.created_at)} />
        <Fact label="Codex Thread" value={event.codex_thread_id} />
        <Fact label="Codex Turn" value={event.codex_turn_id} />
        <Fact label="Codex Item" value={event.codex_item_id} />
      </section>

      <section className="tracing-section">
        <h3>Trace Event Row</h3>
        <JsonBlock label="Complete row" value={eventRow} maxHeight={520} />
      </section>

      <section className="tracing-section">
        <h3>Versioned Data</h3>
        <div className="tracing-json-stack">
          <JsonBlock label="Payload" value={event.payload} maxHeight={520} />
          <JsonBlock label="Raw" value={event.raw} maxHeight={520} />
          <JsonBlock label={`Omitted (${omittedCount(event.omitted)})`} value={event.omitted} maxHeight={320} />
        </div>
      </section>
    </div>
  );
}

function EventTimeline({ title, events = [], emptyLabel, compact = false }) {
  const Heading = compact ? "h4" : "h3";

  return (
    <section className={`tracing-events${compact ? " compact" : ""}`}>
      <Heading>{title}</Heading>
      {events.length === 0 ? (
        <div className="tracing-events-empty">{emptyLabel}</div>
      ) : (
        <div className="tracing-event-list">
          {events.map((event) => (
            <article className="tracing-event" key={event._rowKey || event.id}>
              <header>
                <span className={`tracing-item-dot ${event.status || "completed"}`} />
                <strong>{event.event_name || "event"}</strong>
                <small>
                  {traceEventSubtitle(event)}
                </small>
              </header>
              <dl>
                <DetailField label="ID" value={event.id} />
                <DetailField label="Codex Item" value={event.codex_item_id} />
                <DetailField label="Codex Turn" value={event.codex_turn_id} />
              </dl>
              {Array.isArray(event.omitted) && event.omitted.length > 0 ? (
                <JsonBlock label={`Omitted (${event.omitted.length})`} value={event.omitted} />
              ) : null}
              {hasDisplayableJson(event.payload) ? <JsonBlock label="Payload" value={event.payload} /> : null}
              {hasDisplayableJson(event.raw) ? <JsonBlock label="Raw" value={event.raw} /> : null}
            </article>
          ))}
        </div>
      )}
    </section>
  );
}

function Fact({ label, value }) {
  const displayValue = displayScalar(value);

  return (
    <div>
      <span>{label}</span>
      <strong title={displayValue}>{displayValue}</strong>
    </div>
  );
}

function DetailField({ label, value }) {
  if (isBlankValue(value)) return null;
  const displayValue = displayScalar(value);

  return (
    <>
      <dt>{label}</dt>
      <dd title={displayValue}>{displayValue}</dd>
    </>
  );
}

function JsonBlock({ label, value, defaultOpen = true, maxHeight = 420 }) {
  return (
    <details className="tracing-json" open={defaultOpen}>
      <summary>{label}</summary>
      <CodeBlockRenderer
        value={stringifyJson(value)}
        language="json"
        className="tracing-json-code"
        maxHeight={maxHeight}
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

function normalizeTraceEvents(events = []) {
  if (!Array.isArray(events)) return [];

  return events
    .map((event, index) => {
      const normalized = {
        ...(event && typeof event === "object" ? event : {}),
        id: stringField(event?.id),
        scope: stringField(event?.scope),
        event_name: stringField(event?.event_name),
        thread_id: stringField(event?.thread_id),
        turn_id: stringField(event?.turn_id),
        item_id: stringField(event?.item_id),
        codex_thread_id: stringField(event?.codex_thread_id),
        codex_turn_id: stringField(event?.codex_turn_id),
        codex_item_id: stringField(event?.codex_item_id),
        status: stringField(event?.status),
        payload: typeof event?.payload === "undefined" ? {} : event.payload,
        raw: typeof event?.raw === "undefined" ? null : event.raw,
        omitted: typeof event?.omitted === "undefined" ? [] : event.omitted,
        created_at: stringField(event?.created_at),
        _index: index,
        _rowKey: stringField(event?.id) || `trace-event-${index}`,
      };

      normalized._searchText = traceEventSearchText(normalized);
      return normalized;
    })
    .sort(compareTraceEvents);
}

function filterTraceEvents(events, filters) {
  const query = normalizeSearch(filters.query);
  const eventName = normalizeSearch(filters.eventName);

  return events.filter((event) => {
    if (filters.scope && event.scope !== filters.scope) return false;
    if (filters.status && event.status !== filters.status) return false;
    if (eventName && !normalizeSearch(event.event_name).includes(eventName)) return false;
    if (query && !event._searchText.includes(query)) return false;
    return true;
  });
}

function traceFilterOptions(events) {
  return {
    scopes: uniqueSorted(events.map((event) => event.scope).filter(Boolean)),
    statuses: uniqueSorted(events.map((event) => event.status).filter(Boolean)),
  };
}

function groupTimelineEvents(events, threadId) {
  const groups = new Map();

  events.forEach((event) => {
    const id = event.turn_id || `thread-${event.thread_id || threadId || "unknown"}`;
    if (!groups.has(id)) {
      groups.set(id, {
        id,
        type: event.turn_id ? "turn" : "thread",
        threadId: event.thread_id || threadId || "",
        turnId: event.turn_id || "",
        status: event.status || "",
        createdAt: event.created_at,
        events: [],
      });
    }

    const group = groups.get(id);
    group.events.push(event);
    group.status = event.status || group.status;
    group.createdAt = earliestTime(group.createdAt, event.created_at);
  });

  return Array.from(groups.values()).sort((left, right) =>
    compareNullableTime(left.createdAt, right.createdAt) || left.id.localeCompare(right.id),
  );
}

function timelineGroupKey(group) {
  return `group:${group.id}`;
}

function timelineEventKey(event) {
  return `event:${event._rowKey}`;
}

function timelineSelectionExists(groups, selectedKey) {
  if (!selectedKey) return false;

  return groups.some((group) => {
    if (timelineGroupKey(group) === selectedKey) return true;
    return group.events.some((event) => timelineEventKey(event) === selectedKey);
  });
}

function timelineGroupMarkdown(group) {
  const lastEvent = group.events[group.events.length - 1] || null;
  const heading = group.type === "thread" ? "Thread Events" : `Turn ${group.turnId || group.id}`;
  const timelineRows = group.events.map((event, index) =>
    [
      index + 1,
      markdownTableCell(event.created_at),
      markdownTableCell(event.scope),
      markdownTableCell(codexRpcPayloadValue(event, "method")),
      markdownTableCell(codexRpcPayloadValue(event, "direction")),
      markdownTableCell(codexRpcPayloadValue(event, "rpc_id")),
      markdownTableCell(event.event_name),
      markdownTableCell(event.status),
      markdownTableCell(event.item_id),
      markdownTableCell(event.codex_item_id),
    ].join(" | "),
  );

  const eventRows = group.events.flatMap((event, index) => [
    `### ${index + 1}. ${event.event_name || "event"}`,
    "",
    `- Event ID: ${event.id || "-"}`,
    `- Created: ${event.created_at || "-"}`,
    `- Scope: ${event.scope || "-"}`,
    `- RPC Method: ${codexRpcPayloadValue(event, "method") || "-"}`,
    `- Direction: ${codexRpcPayloadValue(event, "direction") || "-"}`,
    `- RPC ID: ${codexRpcPayloadValue(event, "rpc_id") || "-"}`,
    `- Status: ${event.status || "-"}`,
    `- Item ID: ${event.item_id || "-"}`,
    `- Codex Turn ID: ${event.codex_turn_id || "-"}`,
    `- Codex Item ID: ${event.codex_item_id || "-"}`,
    "",
    "```json",
    stringifyJson(publicEventRow(event)),
    "```",
    "",
  ]);

  return [
    `# ${heading}`,
    "",
    "## Summary",
    "",
    `- Thread ID: ${group.threadId || "-"}`,
    `- Turn ID: ${group.turnId || "-"}`,
    `- Event count: ${group.events.length}`,
    `- First event: ${group.createdAt || "-"}`,
    `- Last event: ${lastEvent?.created_at || "-"}`,
    `- Latest status: ${group.status || "-"}`,
    "",
    "## Timeline",
    "",
    "# | Created | Scope | RPC Method | Direction | RPC ID | Event | Status | Item ID | Codex Item ID",
    "--- | --- | --- | --- | --- | --- | --- | --- | --- | ---",
    ...timelineRows,
    "",
    "## Event Rows",
    "",
    ...eventRows,
  ].join("\n");
}

function markdownTableCell(value) {
  return String(value || "-").replace(/\|/g, "\\|").replace(/\n/g, " ");
}

function traceEventSubtitle(event) {
  return [event.scope, codexRpcSummary(event), event.status, formatTime(event.created_at)].filter(Boolean).join(" · ");
}

function codexRpcSummary(event) {
  if (event?.scope !== "codex_rpc") return "";

  const method = codexRpcPayloadValue(event, "method");
  const direction = codexRpcPayloadValue(event, "direction");
  const rpcId = codexRpcPayloadValue(event, "rpc_id");
  return [direction, method, rpcId ? `#${rpcId}` : ""].filter(Boolean).join(" ");
}

function codexRpcPayloadValue(event, key) {
  if (event?.scope !== "codex_rpc" || !event.payload || typeof event.payload !== "object") return "";
  return event.payload[key] ?? "";
}

function traceEventSearchText(event) {
  return normalizeSearch(
    [
      event.id,
      event.scope,
      event.event_name,
      event.thread_id,
      event.turn_id,
      event.item_id,
      event.codex_thread_id,
      event.codex_turn_id,
      event.codex_item_id,
      event.status,
      stringifyJson(event.payload),
      stringifyJson(event.raw),
      stringifyJson(event.omitted),
      stringifyJson(publicEventRow(event)),
    ].join("\n"),
  );
}

function publicEventRow(event) {
  return Object.fromEntries(
    Object.entries(event || {}).filter(([key]) => !key.startsWith("_")),
  );
}

function compareTraceEvents(left, right) {
  return compareNullableTime(left.created_at, right.created_at) || left._index - right._index;
}

function compareNullableTime(left, right) {
  const leftTime = Date.parse(left || "");
  const rightTime = Date.parse(right || "");
  const leftValid = !Number.isNaN(leftTime);
  const rightValid = !Number.isNaN(rightTime);

  if (leftValid && rightValid) return leftTime - rightTime;
  if (leftValid) return -1;
  if (rightValid) return 1;
  return 0;
}

function earliestTime(left, right) {
  if (!left) return right || "";
  if (!right) return left || "";
  return compareNullableTime(left, right) <= 0 ? left : right;
}

function uniqueSorted(values) {
  return [...new Set(values)].sort((left, right) => left.localeCompare(right));
}

function stringField(value) {
  if (value === null || typeof value === "undefined") return "";
  return typeof value === "string" ? value : String(value);
}

function normalizeSearch(value) {
  return String(value || "").toLowerCase().trim();
}

function groupTracingTurns(items) {
  const groups = new Map();

  const itemList = Array.isArray(items) ? items : [];

  [...itemList].sort(compareItems).forEach((item) => {
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
        events: [],
        items: [],
      });
    }

    groups.get(id).items.push(item);
  });

  return Array.from(groups.values()).sort((left, right) =>
    compareNullableTime(left.createdAt, right.createdAt) || left.id.localeCompare(right.id),
  );
}

function compareItems(left, right) {
  return compareNullableTime(left.created_at, right.created_at) || stringField(left.id).localeCompare(stringField(right.id));
}

function turnLabel(turn, index = null) {
  const prefix = index === null ? "Turn" : `Turn ${index + 1}`;
  if (turn.userText) return `${prefix}: ${truncateLine(turn.userText, 64)}`;
  return `${prefix} ${shortId(turn.id)}`;
}

function timelineGroupLabel(group, index = null) {
  const prefix = group.type === "thread" ? "Thread Events" : index === null ? "Turn" : `Turn ${index + 1}`;
  if (group.turnId) return `${prefix} ${shortId(group.turnId)}`;
  return prefix;
}

function timelineGroupIndexLabel(group, index = null) {
  if (group.type === "thread") return "T";
  return index === null ? "-" : index + 1;
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

function hasDisplayableJson(value) {
  if (value === null || typeof value === "undefined") return false;
  if (Array.isArray(value)) return value.length > 0;
  if (typeof value === "object") return Object.keys(value).length > 0;
  return true;
}

function stringifyJson(value) {
  if (typeof value === "undefined") return "undefined";

  try {
    const jsonValue = JSON.stringify(value, null, 2);
    return typeof jsonValue === "string" ? jsonValue : String(value);
  } catch (_error) {
    return String(value);
  }
}

function omittedCount(value) {
  return Array.isArray(value) ? value.length : 0;
}

function displayScalar(value) {
  if (isBlankValue(value)) return "-";
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  return stringifyJson(value);
}

function isBlankValue(value) {
  return value === null || typeof value === "undefined" || value === "";
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

function emptyEventDetailMessage(status, project, totalEvents) {
  if (!project) return "No project is selected.";
  if (status === "loading") return "Trace events are loading.";
  if (status === "error") return "Trace events could not be loaded.";
  if (totalEvents === 0) return "No trace events are recorded for this thread.";
  if (totalEvents > 0) return "No event matches the current filters.";
  return "Select an event in the timeline.";
}
