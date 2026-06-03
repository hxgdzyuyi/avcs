import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import ProjectPane from "./features/projects/ProjectPane.jsx";
import ChatPane from "./features/chat/ChatPane.jsx";
import BoardPane from "./features/board/BoardPane.jsx";
import TracingPage from "./features/tracing/TracingPage.jsx";
import SettingsPage from "./features/settings/SettingsPage.jsx";
import { createAvcsChannel } from "./socket/client.js";
import {
  createBlankProject,
  deleteAsset,
  openProject,
  readAssetPath,
  revealAsset,
  scanAssets,
  uploadAsset,
} from "./api.js";

const SUPPORTED_REFERENCE_IMAGE_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
]);
const MESSAGE_PAGE_LIMIT = 30;
const DEFAULT_SITE_SETTINGS = {
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

export default function App() {
  const [channel, setChannel] = useState(null);
  const [connectionState, setConnectionState] = useState("connecting");
  const [routePath, setRoutePath] = useState(() => window.location.pathname);
  const [project, setProject] = useState(null);
  const [projects, setProjects] = useState([]);
  const [projectPath, setProjectPath] = useState("");
  const [threads, setThreads] = useState([]);
  const [threadsByProjectId, setThreadsByProjectId] = useState({});
  const [currentThreadId, setCurrentThreadId] = useState(null);
  const [draftThreadProjectId, setDraftThreadProjectId] = useState(null);
  const [items, setItems] = useState([]);
  const [messagePaging, setMessagePaging] = useState(() =>
    defaultMessagePaging(),
  );
  const [assets, setAssets] = useState([]);
  const [boardItems, setBoardItems] = useState([]);
  const [references, setReferences] = useState([]);
  const [pendingReferences, setPendingReferences] = useState([]);
  const [prompt, setPrompt] = useState("");
  const [runningTurns, setRunningTurns] = useState({});
  const [repairingThreads, setRepairingThreads] = useState({});
  const [streamingByTurn, setStreamingByTurn] = useState({});
  const [modelOptions, setModelOptions] = useState([]);
  const [siteSettings, setSiteSettings] = useState(DEFAULT_SITE_SETTINGS);
  const [siteSettingItems, setSiteSettingItems] = useState([]);
  const [composerSettings, setComposerSettings] = useState(
    defaultComposerSettings(),
  );
  const [imageSettings, setImageSettings] = useState(defaultImageSettings());
  const [selectedBoardIds, setSelectedBoardIds] = useState([]);
  const [boardFocusRequest, setBoardFocusRequest] = useState(null);
  const [mobileView, setMobileView] = useState("thread");
  const [notice, setNotice] = useState("");
  const [expandedProjectIds, setExpandedProjectIds] = useState([]);
  const [showAllThreadProjectIds, setShowAllThreadProjectIds] = useState([]);
  const [collapsedLeftAndMiddle, setCollapsedLeftAndMiddle] = useState(false);
  const currentThreadIdRef = useRef(null);
  const draftThreadProjectIdRef = useRef(null);
  const projectIdRef = useRef(null);
  const itemsRef = useRef([]);
  const messagePagingRef = useRef(messagePaging);
  const messagePageRequestsRef = useRef({});
  const messageRequestSeqRef = useRef(0);
  const runningTurnsRef = useRef({});
  const isProjectRouteSyncRef = useRef(false);
  const pendingReferencePreviewsRef = useRef(new Map());
  const settingsBackPathRef = useRef(null);

  useEffect(() => {
    currentThreadIdRef.current = currentThreadId;
  }, [currentThreadId]);

  useEffect(() => {
    draftThreadProjectIdRef.current = draftThreadProjectId;
  }, [draftThreadProjectId]);

  useEffect(() => {
    projectIdRef.current = project?.id || null;
  }, [project?.id]);

  useEffect(() => {
    itemsRef.current = items;
  }, [items]);

  useEffect(() => {
    messagePagingRef.current = messagePaging;
  }, [messagePaging]);

  useEffect(() => {
    runningTurnsRef.current = runningTurns;
  }, [runningTurns]);

  useEffect(() => {
    return () => {
      revokePendingReferencePreviews(pendingReferencePreviewsRef.current);
    };
  }, []);

  useEffect(() => {
    const { projectId, threadId } = parseProjectRoute(routePath);
    if (!projectId || !channel) return;

    if (isProjectRouteSyncRef.current) {
      isProjectRouteSyncRef.current = false;
      return;
    }

    async function applyRoute() {
      isProjectRouteSyncRef.current = true;
      try {
        if (project?.id !== projectId) {
          if (threadId) {
            await handleSelectProject(projectId, { syncRoute: false });

            let threadItems = threadsByProjectId[projectId] || [];
            if (!threadItems.some((thread) => thread.id === threadId)) {
              threadItems = await loadProjectThreads(projectId);
            }

            if (threadItems.some((thread) => thread.id === threadId)) {
              await handleSelectThread(threadId, projectId, {
                syncRoute: false,
              });
            } else {
              await handlePrepareNewThread(projectId, { syncRoute: false });
            }

            return;
          }

          await handlePrepareNewThread(projectId, { syncRoute: false });
          return;
        }

        if (!threadId) {
          if (draftThreadProjectIdRef.current !== projectId) {
            await handlePrepareNewThread(projectId, { syncRoute: false });
          }
          return;
        }

        const projectThreads = threadsByProjectId[projectId] || [];
        let hasThread = projectThreads.some((thread) => thread.id === threadId);
        if (!hasThread) {
          const refreshed = await loadProjectThreads(projectId);
          hasThread = refreshed.some((thread) => thread.id === threadId);
        }

        if (
          hasThread &&
          (threadId !== currentThreadIdRef.current ||
            draftThreadProjectIdRef.current === projectId)
        ) {
          await handleSelectThread(threadId, projectId, { syncRoute: false });
          return;
        }

        if (!hasThread) {
          await handlePrepareNewThread(projectId, { syncRoute: false });
        }
      } catch (error) {
        setNotice(error.message);
      } finally {
        isProjectRouteSyncRef.current = false;
      }
    }

    applyRoute();
  }, [channel, routePath]);

  useEffect(() => {
    function handlePopState() {
      setRoutePath(window.location.pathname);
    }

    window.addEventListener("popstate", handlePopState);
    return () => window.removeEventListener("popstate", handlePopState);
  }, []);

  const refreshAll = useCallback(
    async (threadId = currentThreadId, activeProject = project) => {
      if (!channel || !activeProject) return;
      const [threadData, assetData, boardData] = await Promise.all([
        channel.push("threads:list", { project_id: activeProject.id }),
        channel.push("assets:list"),
        channel.push("board:items:list"),
      ]);
      const threadItems = threadData.items || [];

      setThreads(threadItems);
      setThreadsByProjectId((current) => ({
        ...current,
        [activeProject.id]: threadItems,
      }));
      setAssets(assetData.items || []);
      setBoardItems(boardData.items || []);
      setSelectedBoardIds((current) =>
        current.filter((id) =>
          (boardData.items || []).some((item) => item.id === id),
        ),
      );

      const keepDraft =
        draftThreadProjectIdRef.current === activeProject.id && !threadId;
      const selectedThreadId = keepDraft
        ? null
        : validThreadId(threadItems, threadId) ||
          validThreadId(threadItems, activeProject.current_thread_id) ||
          threadItems[0]?.id ||
          null;
      currentThreadIdRef.current = selectedThreadId;
      setCurrentThreadId(selectedThreadId);

      if (selectedThreadId) {
        await requestItemPage(
          selectedThreadId,
          "latest",
          {},
          { replace: true, scrollToBottom: true },
        );
      } else {
        resetMessageWindow(null);
      }

      return selectedThreadId;
    },
    [channel, currentThreadId, project],
  );

  const refreshProjects = useCallback(async () => {
    if (!channel) return;
    const data = await channel.push("projects:list");
    setProjects(data.items || []);
  }, [channel]);

  const loadProjectThreads = useCallback(
    async (projectId) => {
      if (!channel || !projectId) return [];
      const data = await channel.push("threads:list", {
        project_id: projectId,
      });
      const items = data.items || [];
      setThreadsByProjectId((current) => ({ ...current, [projectId]: items }));
      if (project?.id === projectId) setThreads(items);
      return items;
    },
    [channel, project],
  );

  async function requestItemPage(
    threadId,
    mode = "latest",
    pagePayload = {},
    options = {},
  ) {
    if (!channel || !threadId) return null;

    const pageMode = mode || "latest";
    if (messagePageRequestsRef.current[pageMode]) return null;

    const requestId = `${pageMode}-${Date.now()}-${++messageRequestSeqRef.current}`;
    const loadingField = loadingFieldForPageMode(pageMode);
    messagePageRequestsRef.current[pageMode] = requestId;
    const threadChanged = messagePagingRef.current.threadId !== threadId;

    if (threadChanged) {
      itemsRef.current = [];
      setItems([]);
    }

    setMessagePaging((current) => ({
      ...(options.replace || current.threadId !== threadId
        ? defaultMessagePaging(threadId)
        : current),
      threadId,
      [loadingField]: true,
    }));

    try {
      const data = await channel.push("thread:items:page", {
        thread_id: threadId,
        limit: options.limit || MESSAGE_PAGE_LIMIT,
        ...pagePayload,
        request_id: requestId,
      });

      if (
        data.request_id !== requestId ||
        data.thread_id !== currentThreadIdRef.current
      )
        return null;

      applyMessagePage(data, pageMode, options);
      return data;
    } catch (error) {
      setNotice(error.message);
      throw error;
    } finally {
      if (messagePageRequestsRef.current[pageMode] === requestId) {
        delete messagePageRequestsRef.current[pageMode];
        setMessagePaging((current) => ({ ...current, [loadingField]: false }));
      }
    }
  }

  function applyMessagePage(data, mode, options = {}) {
    const page = data.page || {};
    const pageItems = data.items || [];
    const currentItems = itemsRef.current;
    const replacing = options.replace || mode === "latest" || mode === "around";
    const nextItems = replacing
      ? pageItems
      : mode === "before"
        ? mergeItems(pageItems, currentItems)
        : mergeItems(currentItems, pageItems);

    itemsRef.current = nextItems;
    setItems(nextItems);

    const loadedTurnIds = turnIdSet(nextItems);
    setMessagePaging((current) => {
      const next = {
        ...current,
        threadId: data.thread_id,
        loadedTurnIds,
        beforeCursor: cursorForMode(
          current.beforeCursor,
          page.before_cursor,
          mode,
          "before",
        ),
        afterCursor: cursorForMode(
          current.afterCursor,
          page.after_cursor,
          mode,
          "after",
        ),
        hasMoreBefore:
          mode === "before"
            ? Boolean(page.has_more_before)
            : replacing
              ? Boolean(page.has_more_before)
              : current.hasMoreBefore,
        hasMoreAfter:
          mode === "after"
            ? Boolean(page.has_more_after)
            : replacing
              ? Boolean(page.has_more_after)
              : current.hasMoreAfter,
        atLatest:
          mode === "before" ? current.atLatest : Boolean(page.at_latest),
        hasLoadedEarlier:
          mode === "latest"
            ? false
            : mode === "before" && Number(page.turn_count) > 0
              ? true
              : current.hasLoadedEarlier,
        initialLoaded: true,
        pendingNewItems: mode === "latest" ? [] : current.pendingNewItems,
        pendingNewTurnIds:
          mode === "latest" ? new Set() : current.pendingNewTurnIds,
        pendingNewCount: mode === "latest" ? 0 : current.pendingNewCount,
      };

      if (options.scrollToBottom || mode === "latest") {
        next.scrollToBottomRequest = Date.now();
        next.isAtBottom = true;
      }

      if (mode === "around" && page.anchor_turn_id) {
        next.highlightedTurnId = page.anchor_turn_id;
      }

      return next;
    });
  }

  function resetMessageWindow(threadId = null) {
    messagePageRequestsRef.current = {};
    itemsRef.current = [];
    setItems([]);
    setMessagePaging(defaultMessagePaging(threadId));
  }

  function replaceMessageWindowFromItems(threadId, nextItems) {
    const items = nextItems || [];
    itemsRef.current = items;
    setItems(items);
    setMessagePaging({
      ...defaultMessagePaging(threadId),
      loadedTurnIds: turnIdSet(items),
      beforeCursor: cursorFromItem(firstTurnItem(items)),
      afterCursor: cursorFromItem(lastTurnItem(items)),
      initialLoaded: true,
      atLatest: true,
      scrollToBottomRequest: Date.now(),
    });
  }

  function mergeCreatedMessageItem(payload) {
    const item = payload?.item;
    if (!item?.id) return;

    const paging = messagePagingRef.current;
    const turnId = item.turn_id || payload.turn_id;
    const activeTurn = runningTurnsRef.current[payload.thread_id]?.turn_id;
    const turnLoaded = turnId ? paging.loadedTurnIds.has(turnId) : false;
    const shouldAppend =
      turnLoaded ||
      activeTurn === turnId ||
      item.type === "user_message" ||
      (paging.atLatest && paging.isAtBottom);

    if (shouldAppend) {
      const nextItems = upsertById(itemsRef.current, item);
      itemsRef.current = nextItems;
      setItems(nextItems);

      setMessagePaging((current) => {
        const loadedTurnIds = new Set(current.loadedTurnIds);
        if (turnId) loadedTurnIds.add(turnId);

        const pendingNewItems = current.pendingNewItems.filter(
          (pending) => pending.id !== item.id,
        );
        const pendingNewTurnIds = turnIdSet(pendingNewItems);
        const afterCursor = cursorFromItem(item) || current.afterCursor;

        return {
          ...current,
          loadedTurnIds,
          afterCursor,
          pendingNewItems,
          pendingNewTurnIds,
          pendingNewCount: pendingNewTurnIds.size,
          scrollToBottomRequest:
            current.isAtBottom ||
            activeTurn === turnId ||
            item.type === "user_message"
              ? Date.now()
              : current.scrollToBottomRequest,
        };
      });
      return;
    }

    setMessagePaging((current) => {
      const pendingNewItems = upsertById(current.pendingNewItems, item);
      const pendingNewTurnIds = turnIdSet(pendingNewItems);

      return {
        ...current,
        pendingNewItems,
        pendingNewTurnIds,
        pendingNewCount: pendingNewTurnIds.size,
        hasMoreAfter: true,
      };
    });
  }

  function mergeUpdatedMessageItem(item) {
    if (!item?.id || !item.turn_id) return;
    const paging = messagePagingRef.current;
    if (!paging.loadedTurnIds.has(item.turn_id)) return;

    const nextItems = upsertById(itemsRef.current, item);
    itemsRef.current = nextItems;
    setItems(nextItems);
  }

  function markTurnStatus(turnId, status) {
    if (!turnId) return;

    const nextItems = itemsRef.current.map((item) =>
      item.turn_id === turnId ? { ...item, turn_status: status } : item,
    );
    itemsRef.current = nextItems;
    setItems(nextItems);
  }

  function handleMessageBottomChange(isAtBottom) {
    setMessagePaging((current) =>
      current.isAtBottom === isAtBottom ? current : { ...current, isAtBottom },
    );
  }

  async function handleLoadEarlierItems() {
    const paging = messagePagingRef.current;
    if (
      !currentThreadIdRef.current ||
      !paging.hasMoreBefore ||
      !paging.beforeCursor ||
      paging.loadingBefore
    )
      return;

    await requestItemPage(currentThreadIdRef.current, "before", {
      before: paging.beforeCursor,
    });
  }

  async function handleReturnToLatestItems() {
    const threadId = currentThreadIdRef.current;
    if (!threadId) return;

    const paging = messagePagingRef.current;
    if (paging.pendingNewItems.length > 0 && paging.atLatest) {
      const nextItems = mergeItems(itemsRef.current, paging.pendingNewItems);
      itemsRef.current = nextItems;
      setItems(nextItems);
      setMessagePaging((current) => ({
        ...current,
        loadedTurnIds: turnIdSet(nextItems),
        afterCursor:
          cursorFromItem(lastTurnItem(nextItems)) || current.afterCursor,
        pendingNewItems: [],
        pendingNewTurnIds: new Set(),
        pendingNewCount: 0,
        scrollToBottomRequest: Date.now(),
        isAtBottom: true,
      }));
      return;
    }

    await requestItemPage(
      threadId,
      "latest",
      {},
      { replace: true, scrollToBottom: true },
    );
  }

  async function handleLoadAroundTurn(turnId) {
    const threadId = currentThreadIdRef.current;
    if (!threadId || !turnId) return;

    await requestItemPage(
      threadId,
      "around",
      { around: { turn_id: turnId } },
      { replace: true },
    );
  }

  useEffect(() => {
    const client = createAvcsChannel((event, payload) => {
      if (event === "project:updated") {
        setProject(payload.project);
        setProjectPath(payload.project?.folder_path || "");
        if (payload.project?.id) {
          setExpandedProjectIds((current) =>
            current.includes(payload.project.id)
              ? current
              : [payload.project.id, ...current],
          );
        } else {
          clearWorkspaceState();
        }
      }
      if (event === "projects:updated") {
        setProjects(payload.items || []);
      }
      if (event === "site_settings:updated") {
        applySiteSettings(payload);
      }
      if (event === "threads:updated") {
        if (payload.project_id) {
          setThreadsByProjectId((current) => ({
            ...current,
            [payload.project_id]: payload.items || [],
          }));
        }
        if (
          !payload.project_id ||
          payload.project_id === projectIdRef.current
        ) {
          setThreads(payload.items || []);

          const hasCurrentThreadId = Object.prototype.hasOwnProperty.call(
            payload,
            "current_thread_id",
          );
          if (
            hasCurrentThreadId &&
            draftThreadProjectIdRef.current !== payload.project_id
          ) {
            const nextThreadId = validThreadId(
              payload.items || [],
              payload.current_thread_id,
            );
            currentThreadIdRef.current = nextThreadId;
            setCurrentThreadId(nextThreadId);
            setProject((current) =>
              current?.id === payload.project_id
                ? { ...current, current_thread_id: nextThreadId }
                : current,
            );
            if (!nextThreadId) resetMessageWindow(null);
          }
        }
      }
      if (event === "thread:items") {
        if (!belongsToCurrentThread(payload, currentThreadIdRef.current))
          return;
        replaceMessageWindowFromItems(payload.thread_id, payload.items || []);
      }
      if (event === "item:created") {
        if (!belongsToCurrentThread(payload, currentThreadIdRef.current))
          return;
        mergeCreatedMessageItem(payload);
      }
      if (event === "item:updated") {
        if (!belongsToCurrentThread(payload, currentThreadIdRef.current))
          return;
        mergeUpdatedMessageItem(payload.item);
      }
      if (event === "turn:started") {
        setRunningTurns((current) => ({
          ...current,
          [payload.thread_id]: {
            thread_id: payload.thread_id,
            turn_id: payload.turn_id,
            status: "running",
          },
        }));
        if (!belongsToCurrentThread(payload, currentThreadIdRef.current))
          return;
        markTurnStatus(payload.turn_id, payload.turn?.status || "in_progress");
      }
      if (event === "assets:updated") {
        const nextAssets = payload.items || [];
        const nextAssetIds = new Set(nextAssets.map((asset) => asset.id));
        setAssets(nextAssets);
        setReferences((current) =>
          current.filter((id) => nextAssetIds.has(id)),
        );
        setBoardItems((current) =>
          current.filter((item) => nextAssetIds.has(item.asset_id)),
        );
      }
      if (event === "board:items") {
        setBoardItems(payload.items || []);
        setSelectedBoardIds((current) =>
          current.filter((id) =>
            (payload.items || []).some((item) => item.id === id),
          ),
        );
      }
      if (event === "board:item:updated") {
        setBoardItems((current) =>
          current.map((item) =>
            item.id === payload.item.id ? payload.item : item,
          ),
        );
      }
      if (event === "agent:run_started") {
        setRunningTurns((current) => ({
          ...current,
          [payload.thread_id]: {
            thread_id: payload.thread_id,
            turn_id: payload.turn_id,
            status: "running",
          },
        }));
        setStreamingByTurn((current) => ({
          ...current,
          [payload.turn_id]: {
            thread_id: payload.thread_id,
            turn_id: payload.turn_id,
            text: "",
          },
        }));
      }
      if (event === "assistant:delta") {
        if (!belongsToCurrentThread(payload, currentThreadIdRef.current))
          return;
        setStreamingByTurn((current) => {
          const existing = current[payload.turn_id] || {
            thread_id: payload.thread_id,
            turn_id: payload.turn_id,
            text: "",
          };
          return {
            ...current,
            [payload.turn_id]: {
              ...existing,
              text: `${existing.text}${payload.delta || ""}`,
            },
          };
        });
      }
      if (event === "tool:updated") {
        if (!belongsToCurrentThread(payload, currentThreadIdRef.current))
          return;
        if (payload.item) mergeUpdatedMessageItem(payload.item);
      }
      if (event === "approval:requested") {
        setRunningTurns((current) => ({
          ...current,
          [payload.thread_id]: {
            thread_id: payload.thread_id,
            turn_id: payload.turn_id,
            status: "waiting_approval",
          },
        }));
        if (!belongsToCurrentThread(payload, currentThreadIdRef.current))
          return;
        if (payload.item) mergeCreatedMessageItem(payload);
      }
      if (event === "approval:resolved") {
        setRunningTurns((current) => {
          const existing = current[payload.thread_id];
          if (!existing) return current;
          return {
            ...current,
            [payload.thread_id]: { ...existing, status: "running" },
          };
        });
        if (!belongsToCurrentThread(payload, currentThreadIdRef.current))
          return;
        if (payload.item) mergeUpdatedMessageItem(payload.item);
      }
      if (event === "agent:run_completed") {
        setRunningTurns((current) => omitKey(current, payload.thread_id));
        setStreamingByTurn((current) => omitKey(current, payload.turn_id));
        markTurnStatus(payload.turn_id, payload.status || "completed");
      }
      if (
        event === "error" &&
        belongsToCurrentThread(payload, currentThreadIdRef.current)
      ) {
        setNotice(payload.message || "An error occurred");
      }
    });

    client.join
      .then((payload) => {
        setConnectionState("online");
        setProject(payload.project);
        setProjects(payload.projects || []);
        setProjectPath(payload.project?.folder_path || "");
        if (payload.project?.id) setExpandedProjectIds([payload.project.id]);
        setChannel(client);
      })
      .catch((error) => {
        setConnectionState("offline");
        setNotice(error.message);
      });

    return () => client.disconnect();
  }, []);

  useEffect(() => {
    if (!channel) return undefined;

    let cancelled = false;

    channel
      .push("models:list")
      .then((data) => {
        if (!cancelled) setModelOptions(data.items || []);
      })
      .catch((error) => {
        if (!cancelled) setNotice(error.message);
      });

    return () => {
      cancelled = true;
    };
  }, [channel]);

  useEffect(() => {
    if (!channel) return undefined;

    let cancelled = false;

    channel
      .push("site_settings:get")
      .then((data) => {
        if (!cancelled) applySiteSettings(data);
      })
      .catch((error) => {
        if (!cancelled) setNotice(error.message);
      });

    return () => {
      cancelled = true;
    };
  }, [channel]);

  useEffect(() => {
    setImageSettings(defaultImageSettings(siteSettings));
  }, [
    siteSettings["image.default_ratio"],
    siteSettings["image.default_count"],
    siteSettings["image.transparent_background"],
  ]);

  useEffect(() => {
    if (!channel || !project) return;
    const threadId =
      draftThreadProjectId === project.id ? null : project.current_thread_id;
    refreshAll(threadId, project);
  }, [channel, project, draftThreadProjectId]);

  async function handleOpenProject(event) {
    event.preventDefault();
    setNotice("");
    setDraftProjectId(null);
    setPrompt("");
    setReferences([]);
    clearPendingReferences();
    try {
      const opened = await openProject(projectPath);
      setProject(opened);
      setProjects((current) => mergeById([opened, ...current]));
      setSelectedBoardIds([]);
      if (opened.id) {
        setExpandedProjectIds((current) =>
          current.includes(opened.id) ? current : [opened.id, ...current],
        );
      }
      await refreshProjects();
      await refreshAll(opened.current_thread_id, opened);
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleCreateBlankProject() {
    const name = window.prompt("项目名称", "Untitled Project");
    if (!name || !name.trim()) return;
    setNotice("");
    setDraftProjectId(null);
    setPrompt("");
    setReferences([]);
    clearPendingReferences();

    try {
      const created = await createBlankProject(name.trim());
      setProject(created);
      setProjects((current) => mergeById([created, ...current]));
      setProjectPath(created.folder_path || "");
      setSelectedBoardIds([]);
      if (created.id) {
        setExpandedProjectIds((current) =>
          current.includes(created.id) ? current : [created.id, ...current],
        );
      }
      await refreshProjects();
      await refreshAll(created.current_thread_id, created);
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleSelectProject(projectId, { syncRoute = true } = {}) {
    if (!channel) return;
    if (projectId === project?.id && draftThreadProjectId !== projectId) {
      if (syncRoute)
        syncProjectWorkspaceRoute(projectId, currentThreadId, { force: true });
      return;
    }
    setNotice("");
    setDraftProjectId(null);
    setPrompt("");
    setReferences([]);
    clearPendingReferences();

    if (projectId === project?.id) {
      const selectedThreadId = await refreshAll(
        project.current_thread_id,
        project,
      );
      if (syncRoute)
        syncProjectWorkspaceRoute(projectId, selectedThreadId, { force: true });
      return;
    }

    try {
      const data = await channel.push("project:select", { id: projectId });
      const selectedProject = data.project;
      if (syncRoute)
        syncProjectWorkspaceRoute(
          selectedProject.id,
          selectedProject.current_thread_id,
          { force: true },
        );
      currentThreadIdRef.current = selectedProject.current_thread_id || null;
      setCurrentThreadId(selectedProject.current_thread_id || null);
      setProject(selectedProject);
      setProjectPath(selectedProject?.folder_path || "");
      setSelectedBoardIds([]);
      setExpandedProjectIds((current) =>
        current.includes(projectId) ? current : [projectId, ...current],
      );
      const selectedThreadId = await refreshAll(
        selectedProject.current_thread_id,
        selectedProject,
      );
      if (syncRoute)
        syncProjectWorkspaceRoute(selectedProject.id, selectedThreadId, {
          force: true,
        });
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleArchiveProject(projectEntry) {
    if (!channel || !projectEntry?.id) return;
    if (
      !window.confirm(`归档项目“${projectEntry.name}”？项目文件夹不会被删除。`)
    )
      return;
    setNotice("");

    try {
      const data = await channel.push("project:archive", {
        id: projectEntry.id,
      });
      applyProjectRemoval(projectEntry.id, data.project);
      setNotice("项目已归档");
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleDeleteProject(projectEntry) {
    if (!channel || !projectEntry?.id) return;
    if (
      !window.confirm(
        `从项目列表删除“${projectEntry.name}”？这只会删除 SQLite 中的项目引用，不会删除文件夹。`,
      )
    )
      return;
    setNotice("");

    try {
      const data = await channel.push("project:delete", {
        id: projectEntry.id,
      });
      applyProjectRemoval(projectEntry.id, data.project);
      setNotice("项目引用已删除");
    } catch (error) {
      setNotice(error.message);
    }
  }

  function applyProjectRemoval(projectId, activeProject) {
    setProjects((current) => current.filter((entry) => entry.id !== projectId));
    setExpandedProjectIds((current) =>
      current.filter((id) => id !== projectId),
    );
    setShowAllThreadProjectIds((current) =>
      current.filter((id) => id !== projectId),
    );
    setThreadsByProjectId((current) => {
      const next = { ...current };
      delete next[projectId];
      return next;
    });

    if (project?.id === projectId) {
      setProject(activeProject || null);
      setProjectPath(activeProject?.folder_path || "");
      clearWorkspaceState();
    }
  }

  function clearWorkspaceState() {
    setThreads([]);
    currentThreadIdRef.current = null;
    setCurrentThreadId(null);
    setDraftProjectId(null);
    resetMessageWindow(null);
    setAssets([]);
    setBoardItems([]);
    setReferences([]);
    setPrompt("");
    clearPendingReferences();
    setSelectedBoardIds([]);
    setBoardFocusRequest(null);
    setRunningTurns({});
    setRepairingThreads({});
    setStreamingByTurn({});
  }

  async function handleToggleProjectExpanded(projectId) {
    setExpandedProjectIds((current) =>
      current.includes(projectId)
        ? current.filter((id) => id !== projectId)
        : [...current, projectId],
    );

    if (!threadsByProjectId[projectId]) {
      try {
        await loadProjectThreads(projectId);
      } catch (error) {
        setNotice(error.message);
      }
    }
  }

  function handleToggleShowAllThreads(projectId) {
    setShowAllThreadProjectIds((current) =>
      current.includes(projectId)
        ? current.filter((id) => id !== projectId)
        : [...current, projectId],
    );
  }

  async function handlePrepareNewThread(
    projectId = project?.id,
    { syncRoute = true } = {},
  ) {
    if (!channel || !projectId) return;
    setNotice("");

    let activeProject = project;

    try {
      if (projectId !== project?.id) {
        const data = await channel.push("project:select", { id: projectId });
        activeProject = data.project;
        setProject(activeProject);
        setProjectPath(activeProject?.folder_path || "");
      }

      setDraftProjectId(projectId);
      currentThreadIdRef.current = null;
      setCurrentThreadId(null);
      setPrompt("");
      setReferences([]);
      clearPendingReferences();
      resetMessageWindow(null);
      setSelectedBoardIds([]);
      setMobileView("thread");
      setExpandedProjectIds((current) =>
        current.includes(projectId) ? current : [projectId, ...current],
      );

      if (activeProject) {
        await refreshAll(null, activeProject);
      } else if (!threadsByProjectId[projectId]) {
        await loadProjectThreads(projectId);
      }

      if (syncRoute)
        syncProjectWorkspaceRoute(projectId, null, { force: true });
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function createThreadForDraft() {
    const thread = await channel.push("thread:create", {
      title: "Untitled thread",
    });
    setDraftProjectId(null);
    currentThreadIdRef.current = thread.id;
    setCurrentThreadId(thread.id);
    setProject((current) =>
      current ? { ...current, current_thread_id: thread.id } : current,
    );
    resetMessageWindow(thread.id);
    setSelectedBoardIds([]);
    applyThreadUpdate(thread);
    return thread;
  }

  async function handleSelectThread(
    id,
    projectId = project?.id,
    { syncRoute = true } = {},
  ) {
    if (!channel) return;
    let activeProject = project;

    if (projectId && projectId !== project?.id) {
      try {
        const data = await channel.push("project:select", { id: projectId });
        activeProject = data.project;
        setProject(activeProject);
        setProjectPath(activeProject?.folder_path || "");
      } catch (error) {
        setNotice(error.message);
        return;
      }
    }

    setDraftProjectId(null);
    currentThreadIdRef.current = id;
    setCurrentThreadId(id);
    setProject((current) =>
      current?.id === activeProject?.id
        ? { ...current, current_thread_id: id }
        : current,
    );
    setPrompt("");
    setReferences([]);
    clearPendingReferences();
    setSelectedBoardIds([]);
    setMobileView("thread");
    await channel.push("thread:select", { id });
    await refreshAll(id, activeProject);
    if (syncRoute)
      syncProjectWorkspaceRoute(activeProject?.id || projectId, id, {
        force: true,
      });
  }

  async function handleRenameThread(thread) {
    if (!channel) return;
    const title = window.prompt("Thread title", thread.title);
    if (!title || title.trim() === thread.title) return;
    await channel.push("thread:rename", { id: thread.id, title });
    await refreshAll(thread.id);
  }

  async function handleDeleteThread(id) {
    if (!channel) return;
    if (!window.confirm("Archive this thread?")) return;
    const data = await channel.push("thread:delete", { id });
    const nextThreadId = data.current_thread_id || null;
    const activeProject = project
      ? { ...project, current_thread_id: nextThreadId }
      : project;
    setProject(activeProject);
    setDraftProjectId(nextThreadId ? null : activeProject?.id || null);
    currentThreadIdRef.current = nextThreadId;
    setCurrentThreadId(nextThreadId);
    if (!nextThreadId) {
      resetMessageWindow(null);
      setSelectedBoardIds([]);
    }
    await refreshAll(nextThreadId, activeProject);
  }

  async function handleSend() {
    if (!channel || !project) return;
    const text = prompt.trim();
    if (!text && references.length === 0) return;
    const messageText = appendImageSettingsToPrompt(text, imageSettings);
    if (hasUploadingReferences(pendingReferences)) {
      setNotice("Wait for pasted images to finish uploading before sending.");
      return;
    }
    setNotice("");

    try {
      const thread = currentThreadId
        ? { id: currentThreadId }
        : await createThreadForDraft();
      if (project?.id && thread?.id) {
        navigateToPath(buildProjectWorkspacePath(project.id, thread.id));
      }

      const data = await channel.push("message:send", {
        thread_id: thread.id,
        text: messageText,
        asset_ids: references,
        ...settingsPayload(composerSettings),
      });

      if (data.thread) applyThreadUpdate(data.thread);
      setPrompt("");
      setReferences([]);
      setImageSettings(defaultImageSettings(siteSettings));
      clearPendingReferences();
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleStop(run = activeRun) {
    if (!channel || !project || !run?.thread_id || !run?.turn_id) return;

    const previousStatus = run.status || "running";
    setNotice("");
    setRunningTurns((current) => {
      const existing = current[run.thread_id];
      if (!existing || existing.turn_id !== run.turn_id) return current;
      return {
        ...current,
        [run.thread_id]: { ...existing, status: "stopping" },
      };
    });

    try {
      await channel.push("turn:stop", {
        thread_id: run.thread_id,
        turn_id: run.turn_id,
      });
    } catch (error) {
      setRunningTurns((current) => {
        const existing = current[run.thread_id];
        if (!existing || existing.turn_id !== run.turn_id) return current;
        return {
          ...current,
          [run.thread_id]: { ...existing, status: previousStatus },
        };
      });
      setNotice(error.message);
    }
  }

  async function handleComposerSettingsChange(patch) {
    const nextSettings = { ...composerSettings, ...patch };
    setComposerSettings(nextSettings);
    if (!channel || !currentThreadId) return;

    try {
      const thread = await channel.push("thread:settings:update", {
        id: currentThreadId,
        ...settingsPayload(nextSettings),
      });
      applyThreadUpdate(thread);
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleApprovalRespond(item, decision) {
    if (!channel || !item?.payload?.review_id) return;
    setNotice("");

    try {
      const data = await channel.push("approval:respond", {
        thread_id: item.thread_id,
        turn_id: item.turn_id,
        review_id: item.payload.review_id,
        decision,
      });

      if (data.item) mergeUpdatedMessageItem(data.item);
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleUpdateItem(item, content) {
    if (!channel || !item?.id) return;
    setNotice("");

    try {
      const data = await channel.push("item:update", {
        id: item.id,
        content,
      });

      if (data.item) mergeUpdatedMessageItem(data.item);
    } catch (error) {
      setNotice(error.message);
      throw error;
    }
  }

  async function handleSaveSiteSettings(settings) {
    if (!channel) throw new Error("WebSocket disconnected");

    const data = await channel.push("site_settings:update", { settings });
    applySiteSettings(data);
    return data;
  }

  async function handleResetSiteSettings(keys) {
    if (!channel) throw new Error("WebSocket disconnected");

    const data = await channel.push("site_settings:reset", { keys });
    applySiteSettings(data);
    return data;
  }

  function applySiteSettings(data) {
    const nextSettings = normalizeSiteSettings(data?.settings || {});
    setSiteSettings(nextSettings);
    setSiteSettingItems(data?.items || []);
  }

  async function handleRepairThread() {
    if (!channel || !currentThreadId || agentRunning) return;
    const repairThreadId = currentThreadId;
    setNotice("");
    setRepairingThreads((current) => ({ ...current, [repairThreadId]: true }));

    try {
      const data = await channel.push("thread:repair", {
        thread_id: repairThreadId,
      }, 30_000);
      const nextThreads = data.threads || [];
      const nextAssets = data.assets || [];
      const nextBoardItems = data.board_items || [];

      setThreads(nextThreads);
      if (project?.id)
        setThreadsByProjectId((current) => ({
          ...current,
          [project.id]: nextThreads,
        }));
      setAssets(nextAssets);
      setBoardItems(nextBoardItems);
      setSelectedBoardIds((current) =>
        current.filter((id) => nextBoardItems.some((item) => item.id === id)),
      );
      setReferences((current) =>
        current.filter((id) => nextAssets.some((asset) => asset.id === id)),
      );
      await requestItemPage(
        repairThreadId,
        "latest",
        {},
        { replace: true, scrollToBottom: true },
      );

      const repair = data.repair || {};
      setNotice(
        `Thread repaired: ${repair.matched_turns || 0} turns, ${repair.synced_items || 0} items synced.`,
      );
    } catch (error) {
      setNotice(error.message);
    } finally {
      setRepairingThreads((current) => omitKey(current, repairThreadId));
    }
  }

  function setDraftProjectId(projectId) {
    draftThreadProjectIdRef.current = projectId;
    setDraftThreadProjectId(projectId);
  }

  function applyThreadUpdate(thread) {
    if (!thread?.id) return;

    setThreads((current) => upsertThread(current, thread));
    if (project?.id) {
      setThreadsByProjectId((current) => ({
        ...current,
        [project.id]: upsertThread(current[project.id] || [], thread),
      }));
    }
  }

  async function handleUpload(event) {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;

    await uploadReferenceFile(file);
  }

  async function handlePasteImages(files) {
    if (!files?.length) return;

    if (!project) {
      setNotice("Open a project folder first.");
      return;
    }

    for (const file of files) {
      await uploadReferenceFile(file);
    }
  }

  async function uploadReferenceFile(file) {
    if (!file) return false;

    if (!project) {
      setNotice("Open a project folder first.");
      return false;
    }

    if (!isSupportedReferenceImage(file)) {
      setNotice("Unsupported image format. Use PNG, JPEG, GIF, or WebP.");
      return false;
    }

    const pendingId = createPendingReference(file);
    setNotice("");

    try {
      const asset = await uploadAsset(file);
      removePendingReference(pendingId);
      addReference(asset.id);
      await refreshAssetsAndBoard();
      return true;
    } catch (error) {
      markPendingReferenceFailed(pendingId, error.message);
      setNotice(error.message);
      return false;
    }
  }

  async function handleScan() {
    try {
      await scanAssets();
      await refreshAssetsAndBoard();
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function refreshAssetsAndBoard() {
    if (!channel) return;
    const [assetData, boardData] = await Promise.all([
      channel.push("assets:list"),
      channel.push("board:items:list"),
    ]);
    setAssets(assetData.items || []);
    setBoardItems(boardData.items || []);
    setSelectedBoardIds((current) =>
      current.filter((id) =>
        (boardData.items || []).some((item) => item.id === id),
      ),
    );
  }

  function createPendingReference(file) {
    const id = `pending-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const previewUrl = URL.createObjectURL(file);
    pendingReferencePreviewsRef.current.set(id, previewUrl);

    setPendingReferences((current) => [
      ...current,
      {
        id,
        file_name: file.name || "clipboard image",
        preview_url: previewUrl,
        status: "uploading",
        error: "",
      },
    ]);

    return id;
  }

  function markPendingReferenceFailed(id, message) {
    setPendingReferences((current) =>
      current.map((reference) =>
        reference.id === id
          ? {
              ...reference,
              status: "failed",
              error: message || "Upload failed",
            }
          : reference,
      ),
    );
  }

  function removePendingReference(id) {
    const previewUrl = pendingReferencePreviewsRef.current.get(id);
    if (previewUrl) {
      URL.revokeObjectURL(previewUrl);
      pendingReferencePreviewsRef.current.delete(id);
    }

    setPendingReferences((current) =>
      current.filter((reference) => reference.id !== id),
    );
  }

  function clearPendingReferences() {
    revokePendingReferencePreviews(pendingReferencePreviewsRef.current);
    setPendingReferences([]);
  }

  function addReference(assetId) {
    setReferences((current) =>
      current.includes(assetId) ? current : [...current, assetId],
    );
  }

  function handleLocateAsset(assetId) {
    const boardItem = boardItems.find((item) => item.asset_id === assetId);

    if (boardItem) {
      setSelectedBoardIds([boardItem.id]);
      setBoardFocusRequest({ assetId, requestId: Date.now() });
    }

    if (window.matchMedia("(max-width: 1080px)").matches) {
      addReference(assetId);
      setNotice("Board is hidden at this width; image added as a reference.");
    } else if (!boardItem) {
      addReference(assetId);
      setNotice("Image added as a reference.");
    }
  }

  async function handleResize(id, displayWidth, displayHeight, commit) {
    setBoardItems((current) =>
      current.map((item) =>
        item.id === id
          ? {
              ...item,
              display_width: displayWidth,
              display_height: displayHeight,
            }
          : item,
      ),
    );
    if (commit && channel) {
      try {
        await channel.push("board:item:resize", {
          id,
          display_width: displayWidth,
          display_height: displayHeight,
        });
      } catch (error) {
        setNotice(error.message);
        await refreshAssetsAndBoard();
      }
    }
  }

  async function handleUpdateBoardItems(updates, commit) {
    if (!updates?.length) return;

    setBoardItems((current) =>
      current.map((item) => {
        const update = updates.find((candidate) => candidate.id === item.id);
        return update ? { ...item, ...update } : item;
      }),
    );

    if (commit && channel) {
      try {
        const data = await channel.push("board:items:update", {
          items: updates,
        });
        if (data.items?.length) {
          setBoardItems((current) =>
            current.map((item) => {
              const updated = data.items.find((candidate) => candidate.id === item.id);
              return updated || item;
            }),
          );
        }
      } catch (error) {
        setNotice(error.message);
        await refreshAssetsAndBoard();
      }
    }
  }

  async function handleReveal(assetId) {
    try {
      await revealAsset(assetId);
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleCopyPath(assetId) {
    try {
      const data = await readAssetPath(assetId);
      await navigator.clipboard.writeText(data.path);
      setNotice("Path copied");
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleDeleteSelectedBoardItem({ item, selectedCount } = {}) {
    if (selectedCount !== 1 || !item) {
      setNotice("一次只能删除一个文件");
      return;
    }

    const asset = assets.find((candidate) => candidate.id === item.asset_id);
    const fileName = asset?.file_name || item.file_name || "selected image";

    if (
      !window.confirm(
        `删除图片“${fileName}”？这会通过 rm 删除单个文件，操作不可撤销。`,
      )
    )
      return;

    setNotice("");

    try {
      await deleteAsset(item.asset_id);
      setReferences((current) => current.filter((id) => id !== item.asset_id));
      setSelectedBoardIds((current) => current.filter((id) => id !== item.id));
      setBoardItems((current) =>
        current.filter(
          (candidate) =>
            candidate.id !== item.id && candidate.asset_id !== item.asset_id,
        ),
      );
      setAssets((current) =>
        current.filter((candidate) => candidate.id !== item.asset_id),
      );
      await refreshAssetsAndBoard();
      setNotice("图片已删除");
    } catch (error) {
      setNotice(error.message);
    }
  }

  function navigateToPath(path) {
    if (window.location.pathname !== path) {
      window.history.pushState({}, "", path);
    }
    setRoutePath(window.location.pathname);
  }

  function syncProjectWorkspaceRoute(
    projectId,
    threadId,
    { force = false } = {},
  ) {
    if (!projectId || (!force && isProjectRouteSyncRef.current)) return;

    const targetPath = buildProjectWorkspacePath(projectId, threadId);
    if (window.location.pathname === targetPath) return;

    isProjectRouteSyncRef.current = true;
    navigateToPath(targetPath);
  }

  function handleOpenTracing(threadId) {
    if (!threadId) return;
    navigateToPath(`/web/tracing/${encodeURIComponent(threadId)}`);
  }

  function handleOpenSettings() {
    settingsBackPathRef.current = currentWorkspacePath();
    navigateToPath("/web/settings");
  }

  function handleCloseSettings() {
    const targetPath = settingsBackPathRef.current || currentWorkspacePath();
    settingsBackPathRef.current = null;
    navigateToPath(targetPath);
  }

  function currentWorkspacePath() {
    if (!project?.id) return "/web";
    const threadId = draftThreadProjectId === project.id ? null : currentThreadId;
    return buildProjectWorkspacePath(project.id, threadId);
  }

  const isDraftThread = Boolean(project && draftThreadProjectId === project.id);
  const tracingThreadId = parseTracingThreadId(routePath);
  const settingsRoute = parseSettingsRoute(routePath);
  const currentThread = useMemo(
    () =>
      isDraftThread
        ? null
        : threads.find((thread) => thread.id === currentThreadId),
    [isDraftThread, threads, currentThreadId],
  );

  useEffect(() => {
    if (!project?.id || tracingThreadId || settingsRoute || isProjectRouteSyncRef.current)
      return;

    syncProjectWorkspaceRoute(
      project.id,
      isDraftThread ? null : currentThreadId,
    );
  }, [project?.id, isDraftThread, currentThreadId, routePath, settingsRoute]);

  useEffect(() => {
    setComposerSettings(settingsFromThread(currentThread, siteSettings));
  }, [
    currentThread?.id,
    currentThread?.default_model,
    currentThread?.default_effort,
    currentThread?.default_approval_policy,
    currentThread?.default_sandbox_mode,
    siteSettings["agent.default_model"],
    siteSettings["agent.default_effort"],
    siteSettings["agent.default_approval_policy"],
    siteSettings["agent.default_sandbox_mode"],
  ]);

  const projectOpen = Boolean(project);
  const canUseChat = Boolean(project && connectionState === "online");
  const activeRun =
    !isDraftThread && currentThreadId ? runningTurns[currentThreadId] : null;
  const agentRunning = Boolean(activeRun);
  const threadRepairing =
    !isDraftThread && currentThreadId
      ? Boolean(repairingThreads[currentThreadId])
      : false;
  const anyAgentRunning = Object.keys(runningTurns).length > 0;
  const runningThreadIds = Object.keys(runningTurns);
  const streamingText = activeRun
    ? streamingByTurn[activeRun.turn_id]?.text || ""
    : "";

  if (tracingThreadId) {
    return (
      <TracingPage
        channel={channel}
        connectionState={connectionState}
        project={project}
        threadId={tracingThreadId}
        threads={threads}
        onBack={() => navigateToPath("/web")}
      />
    );
  }

  if (settingsRoute) {
    return (
      <SettingsPage
        settingsItems={siteSettingItems}
        settings={siteSettings}
        modelOptions={modelOptions}
        connectionState={connectionState}
        onSave={handleSaveSiteSettings}
        onReset={handleResetSiteSettings}
        onBack={handleCloseSettings}
      />
    );
  }

  return (
    <>
      <nav className="mobile-tabs" aria-label="Workspace views">
        {[
          ["project", "Project"],
          ["thread", "Thread"],
          ["board", "Board"],
        ].map(([value, label]) => (
          <button
            className={mobileView === value ? "active" : ""}
            type="button"
            key={value}
            onClick={() => setMobileView(value)}
          >
            {label}
          </button>
        ))}
      </nav>

      <div
        className={`app-shell${collapsedLeftAndMiddle ? " collapsed-panes" : ""}`}
        data-mobile-view={mobileView}
      >
        <ProjectPane
          project={project}
          projects={projects}
          projectPath={projectPath}
          setProjectPath={setProjectPath}
          threadsByProjectId={threadsByProjectId}
          expandedProjectIds={expandedProjectIds}
          showAllThreadProjectIds={showAllThreadProjectIds}
          currentThreadId={currentThreadId}
          draftThreadProjectId={draftThreadProjectId}
          onOpenProject={handleOpenProject}
          onCreateBlankProject={handleCreateBlankProject}
          onSelectProject={handleSelectProject}
          onToggleProjectExpanded={handleToggleProjectExpanded}
          onToggleShowAllThreads={handleToggleShowAllThreads}
          onCreateThread={handlePrepareNewThread}
          onSelectThread={handleSelectThread}
          onRenameThread={handleRenameThread}
          onDeleteThread={handleDeleteThread}
          onArchiveProject={handleArchiveProject}
          onDeleteProject={handleDeleteProject}
          onOpenSettings={handleOpenSettings}
          connectionState={connectionState}
          agentRunning={anyAgentRunning}
          runningThreadIds={runningThreadIds}
        />

        <section
          className={`workbench${collapsedLeftAndMiddle ? " collapsed-panes" : ""}`}
        >
          <div
            className={`workbench-body${collapsedLeftAndMiddle ? " collapsed-panes" : ""}`}
          >
            <ChatPane
              items={items}
              pagination={messagePaging}
              assets={assets}
              references={references}
              pendingReferences={pendingReferences}
              prompt={prompt}
              setPrompt={setPrompt}
              onSend={handleSend}
              onStop={handleStop}
              onUpload={handleUpload}
              onPasteImages={handlePasteImages}
              onScan={handleScan}
              onOpenTracing={handleOpenTracing}
              onRepairThread={handleRepairThread}
              onLocateAsset={handleLocateAsset}
              onRemoveReference={(assetId) =>
                setReferences((current) =>
                  current.filter((id) => id !== assetId),
                )
              }
              onRemovePendingReference={removePendingReference}
              agentRunning={agentRunning}
              threadRepairing={threadRepairing}
              activeRun={activeRun}
              streamingText={streamingText}
              currentThread={currentThread}
              isDraftThread={isDraftThread}
              projectOpen={projectOpen}
              canUseChat={canUseChat}
              connectionState={connectionState}
              modelOptions={modelOptions}
              siteSettings={siteSettings}
              composerSettings={composerSettings}
              imageSettings={imageSettings}
              defaultImageSettings={defaultImageSettings(siteSettings)}
              onComposerSettingsChange={handleComposerSettingsChange}
              onImageSettingsChange={(patch) =>
                setImageSettings((current) => ({ ...current, ...patch }))
              }
              onApprovalRespond={handleApprovalRespond}
              onUpdateItem={handleUpdateItem}
              onLoadEarlier={handleLoadEarlierItems}
              onReturnToLatest={handleReturnToLatestItems}
              onLoadAroundTurn={handleLoadAroundTurn}
              onBottomStateChange={handleMessageBottomChange}
            />

            <BoardPane
              boardItems={boardItems}
              assets={assets}
              selectedIds={selectedBoardIds}
              setSelectedIds={setSelectedBoardIds}
              projectId={project?.id}
              focusRequest={boardFocusRequest}
              onReferenceAsset={addReference}
              onResize={handleResize}
              onUpdateItems={handleUpdateBoardItems}
              onReveal={handleReveal}
              onCopyPath={handleCopyPath}
              onDeleteSelected={handleDeleteSelectedBoardItem}
              collapsedLeftAndMiddle={collapsedLeftAndMiddle}
              onToggleLeftAndMiddle={() =>
                setCollapsedLeftAndMiddle((value) => !value)
              }
            />
          </div>
        </section>

        {notice ? (
          <div className="notice" role="status">
            <span>{notice}</span>
            <button type="button" onClick={() => setNotice("")}>
              Dismiss
            </button>
          </div>
        ) : null}
      </div>
    </>
  );
}

function mergeById(items) {
  const seen = new Set();
  return items.filter((item) => {
    if (!item || seen.has(item.id)) return false;
    seen.add(item.id);
    return true;
  });
}

function upsertById(items, item) {
  if (!item?.id) return items;
  const found = items.some((entry) => entry.id === item.id);
  if (!found) return [...items, item];
  return items.map((entry) =>
    entry.id === item.id ? { ...entry, ...item } : entry,
  );
}

function mergeItems(first, second) {
  const seen = new Set();
  const merged = [];

  [...(first || []), ...(second || [])].forEach((item) => {
    if (!item?.id || seen.has(item.id)) return;
    seen.add(item.id);
    merged.push(item);
  });

  return merged;
}

function defaultMessagePaging(threadId = null) {
  return {
    threadId,
    loadedTurnIds: new Set(),
    beforeCursor: null,
    afterCursor: null,
    hasMoreBefore: false,
    hasMoreAfter: false,
    hasLoadedEarlier: false,
    atLatest: false,
    isAtBottom: true,
    pendingNewItems: [],
    pendingNewTurnIds: new Set(),
    pendingNewCount: 0,
    loadingLatest: false,
    loadingBefore: false,
    loadingAfter: false,
    loadingAround: false,
    initialLoaded: false,
    scrollToBottomRequest: 0,
    highlightedTurnId: null,
  };
}

function loadingFieldForPageMode(mode) {
  if (mode === "before") return "loadingBefore";
  if (mode === "after") return "loadingAfter";
  if (mode === "around") return "loadingAround";
  return "loadingLatest";
}

function turnIdSet(items) {
  return new Set((items || []).map((item) => item.turn_id).filter(Boolean));
}

function cursorForMode(currentCursor, pageCursor, mode, cursorSide) {
  if (mode === "latest" || mode === "around") return pageCursor || null;
  if (mode === cursorSide) return pageCursor || currentCursor || null;
  return currentCursor || pageCursor || null;
}

function cursorFromItem(item) {
  if (!item?.turn_id) return null;
  const createdAt = item.turn_created_at || item.created_at;
  if (!createdAt) return null;
  return { created_at: createdAt, id: item.turn_id };
}

function firstTurnItem(items) {
  return (items || []).find((item) => item?.turn_id) || null;
}

function lastTurnItem(items) {
  const source = items || [];
  for (let index = source.length - 1; index >= 0; index -= 1) {
    if (source[index]?.turn_id) return source[index];
  }
  return null;
}

function upsertThread(threads, thread) {
  if (!thread?.id) return threads;
  const found = threads.some((entry) => entry.id === thread.id);
  if (!found) return [thread, ...threads];
  return threads.map((entry) =>
    entry.id === thread.id ? { ...entry, ...thread } : entry,
  );
}

function validThreadId(threads, id) {
  if (!id) return null;
  return threads.some((thread) => thread.id === id) ? id : null;
}

function parseTracingThreadId(pathname) {
  const match = String(pathname || "").match(/^\/web\/tracing\/([^/]+)\/?$/);
  return match ? decodeURIComponent(match[1]) : null;
}

function parseSettingsRoute(pathname) {
  return /^\/web\/settings\/?$/.test(String(pathname || ""));
}

function parseProjectRoute(pathname) {
  const match = String(pathname || "").match(
    /^\/web\/projects\/([^/]+)(?:\/threads\/([^/]+))?\/?$/,
  );
  if (!match) return { projectId: null, threadId: null };

  return {
    projectId: safeDecodeRouteParam(match[1]),
    threadId: match[2] ? safeDecodeRouteParam(match[2]) : null,
  };
}

function buildProjectWorkspacePath(projectId, threadId) {
  const encodedProjectId = encodeURIComponent(String(projectId || ""));
  if (!threadId) return `/web/projects/${encodedProjectId}`;
  return `/web/projects/${encodedProjectId}/threads/${encodeURIComponent(String(threadId))}`;
}

function safeDecodeRouteParam(value) {
  try {
    return decodeURIComponent(value || "");
  } catch {
    return value || "";
  }
}

function omitKey(object, key) {
  if (!key || !Object.prototype.hasOwnProperty.call(object, key)) return object;
  const next = { ...object };
  delete next[key];
  return next;
}

function belongsToCurrentThread(payload, currentThreadId) {
  const threadId = payload?.thread_id || payload?.item?.thread_id;
  if (!threadId) return true;
  return threadId === currentThreadId;
}

function hasUploadingReferences(references) {
  return references.some((reference) => reference.status === "uploading");
}

function isSupportedReferenceImage(file) {
  const mimeType = String(file.type || "").toLowerCase();
  if (SUPPORTED_REFERENCE_IMAGE_TYPES.has(mimeType)) return true;
  return /\.(png|jpe?g|gif|webp)$/i.test(file.name || "");
}

function revokePendingReferencePreviews(previews) {
  previews.forEach((previewUrl) => URL.revokeObjectURL(previewUrl));
  previews.clear();
}

function defaultComposerSettings(siteSettings = DEFAULT_SITE_SETTINGS) {
  const settings = normalizeSiteSettings(siteSettings);

  return {
    model: settings["agent.default_model"] || "",
    effort: settings["agent.default_effort"] || "",
    approval_policy: settings["agent.default_approval_policy"] || "never",
    sandbox_mode: settings["agent.default_sandbox_mode"] || "workspace-write",
  };
}

function defaultImageSettings(siteSettings = DEFAULT_SITE_SETTINGS) {
  const settings = normalizeSiteSettings(siteSettings);
  const count = Number(settings["image.default_count"]);

  return {
    image_ratio: settings["image.default_ratio"] || "auto",
    image_count: Number.isInteger(count) ? count : 1,
    transparent_background: Boolean(settings["image.transparent_background"]),
  };
}

function appendImageSettingsToPrompt(text, imageSettings) {
  const settingsText = imageSettingsPromptText(imageSettings);
  if (!settingsText) return text;
  return [text, settingsText].filter(Boolean).join("\n\n");
}

function imageSettingsPromptText(imageSettings) {
  const settings = imageSettings || defaultImageSettings();
  const parts = [];

  if (settings.image_ratio && settings.image_ratio !== "auto") {
    parts.push(`aspect ratio ${settings.image_ratio}`);
  }

  const count = Number(settings.image_count);
  if (Number.isInteger(count) && count > 1) {
    parts.push(`image count ${Math.min(Math.max(count, 1), 4)}`);
  }

  if (settings.transparent_background) {
    parts.push("transparent background");
  }

  return parts.length > 0 ? `Image settings: ${parts.join("; ")}.` : "";
}

function settingsFromThread(thread, siteSettings = DEFAULT_SITE_SETTINGS) {
  const defaults = defaultComposerSettings(siteSettings);

  if (!thread) return defaults;

  return {
    model: thread.default_model || defaults.model || "",
    effort: thread.default_effort || defaults.effort || "",
    approval_policy:
      thread.default_approval_policy || defaults.approval_policy || "never",
    sandbox_mode:
      thread.default_sandbox_mode || defaults.sandbox_mode || "workspace-write",
  };
}

function settingsPayload(settings) {
  return {
    model: settings.model || null,
    effort: settings.effort || null,
    approval_policy: settings.approval_policy || "never",
    sandbox_mode: settings.sandbox_mode || "workspace-write",
  };
}

function normalizeSiteSettings(settings = {}) {
  return {
    ...DEFAULT_SITE_SETTINGS,
    ...(settings || {}),
  };
}
