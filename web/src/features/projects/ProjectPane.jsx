import { useEffect, useMemo, useRef, useState } from "react";
import {
  Archive,
  ChevronDown,
  ChevronRight,
  FilePlus2,
  Folder,
  FolderOpen,
  FolderPlus,
  MoreHorizontal,
  Database,
  Pencil,
  Plus,
  Settings,
  Trash2,
} from "lucide-react";
import IconButton from "../../components/IconButton.jsx";

const DEFAULT_THREAD_LIMIT = 6;
const THINKING_DOT_COUNT = 5;

export default function ProjectPane({
  project,
  projects,
  projectPath,
  setProjectPath,
  threadsByProjectId,
  expandedProjectIds,
  showAllThreadProjectIds,
  currentThreadId,
  draftThreadProjectId,
  onOpenProject,
  onCreateBlankProject,
  onSelectProject,
  onToggleProjectExpanded,
  onToggleShowAllThreads,
  onCreateThread,
  onSelectThread,
  onRenameThread,
  onDeleteThread,
  onArchiveProject,
  onArchiveProjectThreads,
  onDeleteProject,
  onReorderProjects,
  onReorderThreads,
  onShowProjectDbInfo,
  onOpenSettings,
  connectionState,
  agentRunning,
  agentThinkingStep = 0,
  runningThreadIds = [],
}) {
  const [currentProjectMenuOpen, setCurrentProjectMenuOpen] = useState(false);
  const [projectMenuOpen, setProjectMenuOpen] = useState(false);
  const [folderFormOpen, setFolderFormOpen] = useState(false);
  const [activeProjectMenuId, setActiveProjectMenuId] = useState(null);
  const paneRef = useRef(null);

  const orderedProjects = useMemo(() => {
    return mergeCurrentProject(projects || [], project);
  }, [project, projects]);
  const [projectDragState, setProjectDragState] = useState(null);
  const [threadDragState, setThreadDragState] = useState(null);
  const projectRowRefs = useRef({});
  const threadRowRefs = useRef({});
  const hasProjects = orderedProjects.length > 0;
  const showFolderForm = folderFormOpen || !hasProjects;
  const hasOpenMenu = currentProjectMenuOpen || projectMenuOpen || activeProjectMenuId !== null;
  const canReorderProjects =
    connectionState === "online" && typeof onReorderProjects === "function";
  const canReorderThreads = canReorderProjects && typeof onReorderThreads === "function";
  const renderedProjects = projectDragState?.items || orderedProjects;

  useEffect(() => {
    if (!hasOpenMenu) return undefined;

    function handleDocumentPointerDown(event) {
      if (!(event.target instanceof Element)) return;

      const pane = paneRef.current;
      const menuRoot = event.target.closest("[data-project-menu-root]");

      if (pane && menuRoot && pane.contains(menuRoot)) return;

      setCurrentProjectMenuOpen(false);
      setProjectMenuOpen(false);
      setActiveProjectMenuId(null);
    }

    document.addEventListener("pointerdown", handleDocumentPointerDown);
    return () => document.removeEventListener("pointerdown", handleDocumentPointerDown);
  }, [hasOpenMenu]);

  useEffect(() => {
    if (!projectDragState && !threadDragState) return undefined;

    function handlePointerMove(event) {
      if (projectDragState) {
        const nextProjects = moveDraggedProject(event.clientY);
        if (nextProjects) setProjectDragState(nextProjects);
      }

      if (threadDragState) {
        const nextThreads = moveDraggedThread(event.clientY);
        if (nextThreads) setThreadDragState(nextThreads);
      }
    }

    function handlePointerUp() {
      if (projectDragState) {
        const finalIds = projectDragState.items.map((entry) => entry.id);
        const originalIds = orderedProjects.map((entry) => entry.id);

        setProjectDragState(null);
        if (onReorderProjects && finalIds.join("|") !== originalIds.join("|")) {
          onReorderProjects(finalIds);
        }
      }

      if (threadDragState) {
        const projectId = threadDragState.projectId;
        const visibleIds = threadDragState.items.map((entry) => entry.id);
        const baseThreads = getThreadDragBase(projectId);
        const allThreads = threadsByProjectId[projectId] || [];
        const fullOrderedIds = reorderAllThreadIdsFromVisible({
          allThreads,
          visibleThreads: baseThreads,
          visibleOrderedIds: visibleIds,
        });
        const originalIds = allThreads.map((entry) => entry.id);

        setThreadDragState(null);
        if (
          fullOrderedIds &&
          onReorderThreads &&
          fullOrderedIds.join("|") !== originalIds.join("|")
        ) {
          onReorderThreads(projectId, fullOrderedIds);
        }
      }
    }

    document.addEventListener("pointermove", handlePointerMove);
    document.addEventListener("pointerup", handlePointerUp);
    return () => {
      document.removeEventListener("pointermove", handlePointerMove);
      document.removeEventListener("pointerup", handlePointerUp);
    };
  }, [
    orderedProjects,
    projectDragState,
    threadDragState,
    canReorderProjects,
    canReorderThreads,
    onReorderProjects,
    onReorderThreads,
  ]);

  function getThreadDragBase(projectId) {
    const projectThreads = threadsByProjectId[projectId] || [];
    const projectEntry = orderedProjects.find((entry) => entry.id === projectId);
    const showAllThreads = projectEntry
      ? showAllThreadProjectIds.includes(projectId)
      : true;
    return visibleProjectThreads(projectThreads, showAllThreads);
  }

  function setProjectRowRef(projectId, node) {
    const id = String(projectId);
    if (node) {
      projectRowRefs.current[id] = node;
      return;
    }

    delete projectRowRefs.current[id];
  }

  function setThreadRowRef(projectId, threadId, node) {
    const projectKey = String(projectId);
    const existing = threadRowRefs.current[projectKey] || {};
    if (node) {
      existing[threadId] = node;
      threadRowRefs.current[projectKey] = existing;
      return;
    }

    delete existing[threadId];
    if (Object.keys(existing).length === 0) {
      delete threadRowRefs.current[projectKey];
      return;
    }
    threadRowRefs.current[projectKey] = existing;
  }

  function buildRowsWithDragPlaceholder({
    rows,
    sourceId,
    placeholderIndex,
  }) {
    if (
      !Array.isArray(rows) ||
      rows.length === 0 ||
      !Number.isInteger(placeholderIndex) ||
      placeholderIndex < 0 ||
      placeholderIndex > rows.length
    ) {
      return rows.map((entry) => ({ type: "item", item: entry }));
    }

    const sourceIndex = rows.findIndex((entry) => entry.id === sourceId);
    const rendered = [];
    rows.forEach((entry, index) => {
      if (
        index === placeholderIndex &&
        sourceIndex !== index
      ) {
        rendered.push({ type: "placeholder", key: `placeholder-${entry.id}` });
      }

      rendered.push({ type: "item", item: entry, key: entry.id });
    });

    if (
      placeholderIndex === rows.length &&
      sourceIndex !== rows.length &&
      sourceId
    ) {
      rendered.push({ type: "placeholder", key: "placeholder-end" });
    }

    return rendered;
  }

  function moveDraggedProject(clientY) {
    if (!projectDragState || !canReorderProjects) return null;
    const sourceId = projectDragState.sourceId;
    const items = projectDragState.items;
    const sourceIndex = items.findIndex((entry) => entry.id === sourceId);
    if (sourceIndex < 0) return null;

    const withoutSource = items.filter((entry) => entry.id !== sourceId);
    const overIndex = findInsertIndex({
      clientY,
      rows: withoutSource,
      refsMap: projectRowRefs.current,
      skipId: null,
    });

    if (overIndex === null) return null;

    const sourceItem = items.find((entry) => entry.id === sourceId);
    const nextItems = [
      ...withoutSource.slice(0, overIndex),
      sourceItem,
      ...withoutSource.slice(overIndex),
    ];
    if (arraysEqual(nextItems, items)) return null;
    return {
      sourceId,
      items: nextItems,
      placeholderIndex: overIndex,
    };
  }

  function moveDraggedThread(clientY) {
    if (!threadDragState || !canReorderThreads) return null;
    const projectId = threadDragState.projectId;
    const baseThreads = getThreadDragBase(projectId);
    const sourceId = threadDragState.sourceId;
    const source = threadDragState.items.find((entry) => entry.id === sourceId);
    const items = threadDragState.items;
    const withoutSource = items.filter((entry) => entry.id !== sourceId);
    const projectKey = String(projectId);
    const refs = threadRowRefs.current[projectKey] || {};
    const overIndex = findInsertIndex({
      clientY,
      rows: withoutSource,
      refsMap: refs,
      skipId: null,
    });

    if (overIndex === null || !source) return null;

    const nextItems = [
      ...withoutSource.slice(0, overIndex),
      source,
      ...withoutSource.slice(overIndex),
    ];
    if (arraysEqual(nextItems, items)) return null;
    return {
      projectId,
      sourceId,
      items: nextItems,
      placeholderIndex: overIndex,
    };
  }

  function startProjectDrag(event, projectId) {
    if (!canReorderProjects) return;
    const projectEntry = orderedProjects.find((entry) => entry.id === projectId);
    if (!projectEntry || projectEntry.status === "missing" || projectEntry.status === "unavailable") {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    setThreadDragState(null);
    setProjectDragState({
      sourceId: projectId,
      items: [...orderedProjects],
    });
  }

  function startThreadDrag(event, projectId, threadId) {
    if (!canReorderThreads) return;
    if (projectId !== project?.id) return;
    if (!threadsByProjectId[projectId]?.length) return;
    const projectEntry = orderedProjects.find((entry) => entry.id === projectId);
    if (projectEntry?.status === "missing" || projectEntry?.status === "unavailable")
      return;
    event.preventDefault();
    event.stopPropagation();

    const baseThreads = getThreadDragBase(projectId);
    const exists = baseThreads.some((thread) => thread.id === threadId);
    if (!exists) return;
    setProjectDragState(null);
    setThreadDragState({
      projectId,
      sourceId: threadId,
      items: baseThreads,
    });
  }

  function arraysEqual(first, second) {
    if (first.length !== second.length) return false;
    return first.every((value, index) => value.id === second[index]?.id);
  }

  function findInsertIndex({ clientY, rows, refsMap, skipId }) {
    let index = 0;
    for (const row of rows) {
      if (row.id === skipId) continue;
      const node = refsMap[row.id];
      if (!node) {
        index += 1;
        continue;
      }
      const rect = node.getBoundingClientRect();
      const midpoint = rect.top + rect.height / 2;
      if (clientY < midpoint) return index;
      index += 1;
    }

    return rows.length;
  }

  function reorderAllThreadIdsFromVisible({
    allThreads,
    visibleThreads,
    visibleOrderedIds,
  }) {
    if (
      !allThreads ||
      allThreads.length === 0 ||
      !Array.isArray(visibleThreads) ||
      visibleThreads.length === 0
    ) {
      return null;
    }

    const visibleLookup = new Map(
      visibleThreads.map((thread) => [thread.id, thread]),
    );
    const visibleSet = new Set(
      visibleThreads.map((thread) => thread.id),
    );
    const visibleOrdered = visibleOrderedIds
      .map((threadId) => visibleLookup.get(threadId))
      .filter(Boolean);

    if (visibleOrdered.length !== visibleThreads.length) return null;

    const next = [];
    let insertIndex = 0;

    allThreads.forEach((thread) => {
      if (visibleSet.has(thread.id)) {
        next.push(visibleOrdered[insertIndex] || thread);
        insertIndex += 1;
      } else {
        next.push(thread);
      }
    });

    return next.map((thread) => thread.id);
  }

  return (
    <aside className="project-pane" ref={paneRef}>
      <div className="sidebar-header">
        <strong>项目</strong>
        <div className="sidebar-header-actions">
          <span className={`connection-dot ${connectionState}`} title={`WebSocket ${connectionState}`} />
          <IconButton label="全局设置" className="ghost" onClick={onOpenSettings}>
            <Settings size={16} />
          </IconButton>
          <div className="project-menu-wrap" data-project-menu-root>
            <IconButton
              label="创建或添加项目"
              className={projectMenuOpen ? "active" : ""}
              onClick={() => {
                setProjectMenuOpen((open) => !open);
                setCurrentProjectMenuOpen(false);
                setActiveProjectMenuId(null);
              }}
            >
              <FolderPlus size={17} />
            </IconButton>
            {projectMenuOpen ? (
              <div className="project-menu" role="menu">
                <button
                  type="button"
                  onClick={() => {
                    setProjectMenuOpen(false);
                    onCreateBlankProject();
                  }}
                >
                  <FilePlus2 size={15} />
                  <span>新建空白项目</span>
                </button>
                <button
                  type="button"
                  onClick={() => {
                    setFolderFormOpen(true);
                    setProjectMenuOpen(false);
                  }}
                >
                  <FolderOpen size={15} />
                  <span>使用现有文件夹</span>
                </button>
              </div>
            ) : null}
          </div>
        </div>
      </div>

      {showFolderForm ? (
        <form className="project-open" onSubmit={onOpenProject}>
          <input
            value={projectPath}
            onChange={(event) => setProjectPath(event.target.value)}
            placeholder="/absolute/project/folder"
            autoComplete="off"
          />
          <IconButton label="打开项目文件夹" className="primary" type="submit" disabled={!projectPath.trim()}>
            <FolderOpen size={17} />
          </IconButton>
        </form>
      ) : null}

      <div className="sidebar-project-list">
        {hasProjects ? (
          buildRowsWithDragPlaceholder({
            rows: renderedProjects,
            sourceId: projectDragState?.sourceId,
            placeholderIndex: projectDragState?.placeholderIndex,
          }).map((rowState, rowIndex) => {
            if (rowState.type === "placeholder") {
              return (
                <div
                  className="sidebar-project-row-placeholder"
                  key={`project-placeholder-${rowIndex}`}
                />
              );
            }

            const entry = rowState.item;
            const isCurrentProject = entry.id === project?.id;
            const isDraftProject = entry.id === draftThreadProjectId;
            const isExpanded = expandedProjectIds.includes(entry.id);
            const isUnavailable = entry.status && entry.status !== "available";
            const projectThreads = threadsByProjectId[entry.id] || [];
            const showAllThreads = showAllThreadProjectIds.includes(entry.id);
            const visibleThreads = visibleProjectThreads(projectThreads, showAllThreads);
            const hiddenThreadCount = Math.max(projectThreads.length - visibleThreads.length, 0);

            return (
                <div className="sidebar-project-block" key={entry.id}>
              <div
                className={`sidebar-project-row ${isCurrentProject ? "current" : ""} ${
                  isUnavailable ? "unavailable" : ""
                } ${projectDragState?.sourceId === entry.id ? "dragging" : ""} ${
                  canReorderProjects && !isUnavailable ? "draggable" : ""
                }`}
                ref={(node) => setProjectRowRef(entry.id, node)}
                onPointerDown={(event) => startProjectDrag(event, entry.id)}
              >
                <button
                  className="project-disclosure"
                  type="button"
                    aria-label={isExpanded ? "收起项目对话" : "展开项目对话"}
                    onClick={() => onToggleProjectExpanded(entry.id)}
                  >
                    {isExpanded ? <ChevronDown size={15} /> : <ChevronRight size={15} />}
                  </button>
                  <button className="project-select" type="button" title={entry.folder_path} onClick={() => onSelectProject(entry.id)}>
                    <Folder size={15} />
                    <span className="project-label">
                      <span className="project-name">{entry.name}</span>
                      {isUnavailable ? <span className="project-state">{projectStatusLabel(entry.status)}</span> : null}
                    </span>
                  </button>
                  <div className="project-actions" data-project-menu-root>
                    <IconButton
                      label="更多项目操作"
                      className={`ghost ${activeProjectMenuId === entry.id ? "active" : ""}`}
                      onClick={(event) => {
                        event.stopPropagation();
                        setCurrentProjectMenuOpen(false);
                        setProjectMenuOpen(false);
                        setActiveProjectMenuId((current) => (current === entry.id ? null : entry.id));
                      }}
                    >
                      <MoreHorizontal size={14} />
                    </IconButton>
                    <IconButton
                      label="准备新会话"
                      className={`ghost ${isDraftProject ? "active" : ""}`}
                      disabled={isUnavailable}
                      onClick={(event) => {
                        event.stopPropagation();
                        setCurrentProjectMenuOpen(false);
                        setProjectMenuOpen(false);
                        setActiveProjectMenuId(null);
                        onCreateThread(entry.id);
                      }}
                    >
                      <Pencil size={14} />
                    </IconButton>
                    {activeProjectMenuId === entry.id ? (
                      <div className="project-row-menu" role="menu">
                          <button
                            type="button"
                          disabled={isUnavailable}
                          onClick={() => {
                            setActiveProjectMenuId(null);
                            onShowProjectDbInfo?.(entry);
                          }}
                        >
                          <Database size={15} />
                          <span>数据库情况</span>
                        </button>
                        <button
                          type="button"
                          disabled={isUnavailable}
                          onClick={() => {
                            setActiveProjectMenuId(null);
                            onArchiveProject(entry);
                          }}
                        >
                          <Archive size={15} />
                          <span>归档项目</span>
                        </button>
                        <button
                          type="button"
                          disabled={isUnavailable}
                          onClick={() => {
                            setActiveProjectMenuId(null);
                            onArchiveProjectThreads(entry);
                          }}
                        >
                          <Archive size={15} />
                          <span>归档对话</span>
                        </button>
                        <button
                          className="danger"
                          type="button"
                          onClick={() => {
                            setActiveProjectMenuId(null);
                            onDeleteProject(entry);
                          }}
                        >
                          <Trash2 size={15} />
                          <span>删除引用</span>
                        </button>
                      </div>
                    ) : null}
                  </div>
                </div>

                {isExpanded ? (
                  <div className="sidebar-thread-list">
                    {isCurrentProject ? (
                      <button className={`thread-create-row ${isDraftProject ? "active" : ""}`} type="button" onClick={() => onCreateThread(entry.id)}>
                        <Plus size={14} />
                        <span>{isDraftProject ? "准备新对话" : "新对话"}</span>
                      </button>
                    ) : null}
                    {projectThreads.length === 0 ? (
                      <div className="sidebar-empty-row">暂无对话</div>
                    ) : (
                      <>
                        {(() => {
                          const isDraggedProject =
                            threadDragState?.projectId === entry.id;
                          const threadRows = buildRowsWithDragPlaceholder({
                            rows: isDraggedProject
                              ? threadDragState.items
                              : visibleThreads,
                            sourceId: isDraggedProject
                              ? threadDragState.sourceId
                              : null,
                            placeholderIndex: isDraggedProject
                              ? threadDragState.placeholderIndex
                              : null,
                          });
                          const keyboardOrderMap = new Map(
                            (isDraggedProject
                              ? threadDragState.items
                              : visibleThreads
                            ).map((thread, index) => [thread.id, index]),
                          );

                          return threadRows.map((threadRowState, threadRowIndex) => {
                            if (threadRowState.type === "placeholder") {
                              return (
                                <div
                                  className="sidebar-thread-row-placeholder"
                                  key={`thread-placeholder-${threadRowIndex}`}
                                />
                              );
                            }

                          const thread = threadRowState.item;
                          const index = keyboardOrderMap.get(thread.id) || 0;
                          const active = !isDraftProject && isCurrentProject && thread.id === currentThreadId;
                          const running = runningThreadIds.includes(thread.id);
                          const canManage = isCurrentProject;

                          return (
                            <div
                              className={`sidebar-thread-row ${active ? "active" : ""} ${
                                threadDragState?.sourceId === thread.id &&
                                threadDragState?.projectId === entry.id
                                  ? "dragging"
                                  : ""
                              } ${canManage && canReorderThreads && !isUnavailable ? "draggable" : ""}`}
                              key={thread.id}
                              ref={(node) => setThreadRowRef(entry.id, thread.id, node)}
                              onPointerDown={(event) => startThreadDrag(event, entry.id, thread.id)}
                            >
                              <button className="thread-select" type="button" title={thread.title} onClick={() => onSelectThread(thread.id, entry.id)}>
                                <span className="thread-title-text">{thread.title}</span>
                                <span className="thread-side-meta">
                                  {running ? <span className="thread-running-dot" title="Agent running" /> : null}
                                  <span>{formatRelativeTime(thread.updated_at)}</span>
                                  {index < 3 ? <kbd>⌘{index + 1}</kbd> : null}
                                </span>
                              </button>
                              {canManage ? (
                              <span className="thread-actions">
                                  <IconButton
                                    label="重命名对话"
                                    onClick={(event) => {
                                      event.stopPropagation();
                                      onRenameThread(thread);
                                    }}
                                  >
                                    <Pencil size={13} />
                                  </IconButton>
                                  <IconButton
                                    label="归档对话"
                                    onClick={(event) => {
                                      event.stopPropagation();
                                      onDeleteThread(thread.id);
                                    }}
                                  >
                                    <Trash2 size={13} />
                                  </IconButton>
                                </span>
                              ) : null}
                            </div>
                          );
                        });
                        })()}
                        {projectThreads.length > DEFAULT_THREAD_LIMIT ? (
                          <button className="thread-show-more" type="button" onClick={() => onToggleShowAllThreads(entry.id)}>
                            {showAllThreads ? "收起显示" : `展开显示 ${hiddenThreadCount} 个`}
                          </button>
                        ) : null}
                      </>
                    )}
                  </div>
                ) : null}
              </div>
            );
          })
        ) : (
          <div className="project-empty">
            <strong>暂无项目</strong>
            <span>通过文件夹加号添加本地项目。</span>
          </div>
        )}
      </div>

      <div className="project-status" role="status" aria-label="Workspace status">
        <div className="project-status-item">
          <span>WebSocket</span>
          <strong>{connectionState}</strong>
        </div>
        <div className="project-status-item">
          <span>Agent</span>
          <strong>
            {agentRunning ? (
              <ThinkingDots step={agentThinkingStep} />
            ) : (
              "idle"
            )}
          </strong>
        </div>
      </div>
    </aside>
  );
}

function ThinkingDots({ step }) {
  const activeStep = Number.isFinite(step) ? step % THINKING_DOT_COUNT : 0;

  return (
    <span className="agent-thinking-dots" aria-label="thinking">
      {Array.from({ length: THINKING_DOT_COUNT }).map((_, index) => (
        <span
          className={`agent-thinking-dot${index === activeStep ? " active" : ""}`}
          key={index}
        />
      ))}
    </span>
  );
}

function visibleProjectThreads(threads, showAll) {
  if (showAll || threads.length <= DEFAULT_THREAD_LIMIT) return threads;

  return threads.slice(0, DEFAULT_THREAD_LIMIT);
}

function projectStatusLabel(status) {
  if (status === "missing") return "文件夹不可用";
  if (status === "unavailable") return "数据库不可用";
  return "不可用";
}

function formatRelativeTime(value) {
  if (!value) return "";

  const timestamp = Date.parse(value);
  if (!timestamp) return "";

  const minutes = Math.max(0, Math.floor((Date.now() - timestamp) / 60000));
  if (minutes < 1) return "刚刚";
  if (minutes < 60) return `${minutes} 分`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} 时`;

  return `${Math.floor(hours / 24)} 天`;
}

function mergeById(items) {
  const seen = new Set();
  return items.filter((item) => {
    if (!item || seen.has(item.id)) return false;
    seen.add(item.id);
    return true;
  });
}

function mergeCurrentProject(projects, project) {
  const list = mergeById(projects);
  if (!project) return list;

  let found = false;
  const merged = list.map((entry) => {
    if (entry.id !== project.id) return entry;

    found = true;
    return { ...entry, ...project };
  });

  return found ? merged : [...merged, project];
}
