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
  Pencil,
  Plus,
  Trash2,
} from "lucide-react";
import IconButton from "../../components/IconButton.jsx";

const DEFAULT_THREAD_LIMIT = 6;

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
  onDeleteProject,
  connectionState,
  agentRunning,
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

  const hasProjects = orderedProjects.length > 0;
  const showFolderForm = folderFormOpen || !hasProjects;
  const hasOpenMenu = currentProjectMenuOpen || projectMenuOpen || activeProjectMenuId !== null;

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

  return (
    <aside className="project-pane" ref={paneRef}>
      <div className="sidebar-header">
        <strong>项目</strong>
        <div className="sidebar-header-actions">
          <span className={`connection-dot ${connectionState}`} title={`WebSocket ${connectionState}`} />
          <div className="project-menu-wrap" data-project-menu-root>
            <IconButton
              label="更多项目操作"
              className={`ghost ${currentProjectMenuOpen ? "active" : ""}`}
              disabled={!project}
              onClick={() => {
                setCurrentProjectMenuOpen((open) => !open);
                setProjectMenuOpen(false);
                setActiveProjectMenuId(null);
              }}
            >
              <MoreHorizontal size={16} />
            </IconButton>
            {currentProjectMenuOpen && project ? (
              <div className="project-menu" role="menu">
                <button
                  type="button"
                  onClick={() => {
                    setCurrentProjectMenuOpen(false);
                    onArchiveProject(project);
                  }}
                >
                  <Archive size={15} />
                  <span>归档当前项目</span>
                </button>
                <button
                  className="danger"
                  type="button"
                  onClick={() => {
                    setCurrentProjectMenuOpen(false);
                    onDeleteProject(project);
                  }}
                >
                  <Trash2 size={15} />
                  <span>删除引用</span>
                </button>
              </div>
            ) : null}
          </div>
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
          orderedProjects.map((entry) => {
            const isCurrentProject = entry.id === project?.id;
            const isDraftProject = entry.id === draftThreadProjectId;
            const isExpanded = expandedProjectIds.includes(entry.id);
            const isUnavailable = entry.status && entry.status !== "available";
            const projectThreads = threadsByProjectId[entry.id] || [];
            const showAllThreads = showAllThreadProjectIds.includes(entry.id);
            const visibleThreads = visibleProjectThreads(projectThreads, currentThreadId, showAllThreads);
            const hiddenThreadCount = Math.max(projectThreads.length - visibleThreads.length, 0);

            return (
              <div className="sidebar-project-block" key={entry.id}>
                <div className={`sidebar-project-row ${isCurrentProject ? "current" : ""} ${isUnavailable ? "unavailable" : ""}`}>
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
                          onClick={() => {
                            setActiveProjectMenuId(null);
                            onArchiveProject(entry);
                          }}
                        >
                          <Archive size={15} />
                          <span>归档项目</span>
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
                        {visibleThreads.map((thread, index) => {
                          const active = !isDraftProject && isCurrentProject && thread.id === currentThreadId;
                          const running = runningThreadIds.includes(thread.id);
                          const canManage = isCurrentProject;

                          return (
                            <div className={`sidebar-thread-row ${active ? "active" : ""}`} key={thread.id}>
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
                        })}
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

      <div className="project-status">
        <div>
          <span>WebSocket</span>
          <strong>{connectionState}</strong>
        </div>
        <div>
          <span>Agent</span>
          <strong>{agentRunning ? "running" : "idle"}</strong>
        </div>
        <div>
          <span>Files</span>
          <strong>{project ? "ready" : "waiting"}</strong>
        </div>
      </div>
    </aside>
  );
}

function visibleProjectThreads(threads, currentThreadId, showAll) {
  if (showAll || threads.length <= DEFAULT_THREAD_LIMIT) return threads;

  const selected = threads.find((thread) => thread.id === currentThreadId);
  const visible = selected ? [selected, ...threads.filter((thread) => thread.id !== currentThreadId)] : threads;
  return visible.slice(0, DEFAULT_THREAD_LIMIT);
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
