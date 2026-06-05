import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import ProjectPane from "./features/projects/ProjectPane.jsx";
import ProjectDbInfoDialog from "./features/projects/ProjectDbInfoDialog.jsx";
import ChatPane from "./features/chat/ChatPane.jsx";
import BoardPane from "./features/board/BoardPane.jsx";
import TracingPage from "./features/tracing/TracingPage.jsx";
import SettingsPage from "./features/settings/SettingsPage.jsx";
import ConfirmDialog from "./components/ConfirmDialog.jsx";
import PromptDialog from "./components/PromptDialog.jsx";
import ShortcutGuideDialog from "./components/ShortcutGuideDialog.jsx";
import { createAvcsChannel } from "./socket/client.js";
import {
  isShortcutGuideShortcut,
  shouldIgnoreGlobalShortcut,
} from "./keyboard/shortcuts.js";
import {
  createBlankProject,
  deleteAsset,
  openProject,
  readAssetPath,
  revealAsset,
  scanAssets,
  projectSqliteInfo as fetchProjectSqliteInfo,
  projectSqliteMaintenance as runProjectSqliteMaintenance,
  uploadAsset,
  uploadMaskAsset,
} from "./api.js";
import { createTranslator, normalizeLocale } from "./i18n.js";

const SUPPORTED_REFERENCE_IMAGE_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
]);
const MESSAGE_PAGE_LIMIT = 30;
const THINKING_DOT_COUNT = 5;
const BOARD_HISTORY_LIMIT = 50;
const BOARD_HISTORY_FIELDS = [
  "x",
  "y",
  "display_width",
  "display_height",
  "z_index",
];
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
  "ui.locale": "en",
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
  const [boardHistory, setBoardHistory] = useState(() => emptyBoardHistory());
  const [references, setReferences] = useState([]);
  const [pendingReferences, setPendingReferences] = useState([]);
  const [prompt, setPrompt] = useState("");
  const [runningTurns, setRunningTurns] = useState({});
  const [agentThinking, setAgentThinking] = useState({ step: 0, lastAt: null });
  const [repairingThreads, setRepairingThreads] = useState({});
  const [streamingByTurn, setStreamingByTurn] = useState({});
  const [modelOptions, setModelOptions] = useState([]);
  const [siteSettings, setSiteSettings] = useState(DEFAULT_SITE_SETTINGS);
  const [siteSettingItems, setSiteSettingItems] = useState([]);
  const [composerSettings, setComposerSettings] = useState(
    defaultComposerSettings(),
  );
  const [imageSettings, setImageSettings] = useState(defaultImageSettings());
  const [selectedDataProvider, setSelectedDataProvider] = useState(null);
  const [selectedBoardIds, setSelectedBoardIds] = useState([]);
  const [boardFocusRequest, setBoardFocusRequest] = useState(null);
  const [mobileView, setMobileView] = useState("thread");
  const [notice, setNotice] = useState("");
  const [confirmRequest, setConfirmRequest] = useState(null);
  const [promptRequest, setPromptRequest] = useState(null);
  const [expandedProjectIds, setExpandedProjectIds] = useState([]);
  const [showAllThreadProjectIds, setShowAllThreadProjectIds] = useState([]);
  const [collapsedLeftAndMiddle, setCollapsedLeftAndMiddle] = useState(false);
  const [projectSqliteInfo, setProjectSqliteInfo] = useState(null);
  const [projectSqliteInfoProjectId, setProjectSqliteInfoProjectId] =
    useState(null);
  const [projectSqliteInfoLoading, setProjectSqliteInfoLoading] = useState(false);
  const [showProjectDbInfoDialog, setShowProjectDbInfoDialog] = useState(false);
  const [showShortcutGuideDialog, setShowShortcutGuideDialog] = useState(false);
  const [projectSqliteMaintenanceByProject, setProjectSqliteMaintenanceByProject] =
    useState({});
  const currentThreadIdRef = useRef(null);
  const draftThreadProjectIdRef = useRef(null);
  const projectIdRef = useRef(null);
  const projectSqliteInfoProjectIdRef = useRef(null);
  const showProjectDbInfoDialogRef = useRef(false);
  const itemsRef = useRef([]);
  const boardItemsRef = useRef([]);
  const boardItemsLoadedRef = useRef(false);
  const boardHistoryRef = useRef(boardHistory);
  const messagePagingRef = useRef(messagePaging);
  const messagePageRequestsRef = useRef({});
  const messageRequestSeqRef = useRef(0);
  const runningTurnsRef = useRef({});
  const isProjectRouteSyncRef = useRef(false);
  const linkedProjectOpenRef = useRef(false);
  const emptyProjectPromptShownRef = useRef(false);
  const pendingReferencePreviewsRef = useRef(new Map());
  const settingsBackPathRef = useRef(null);
  const confirmResolverRef = useRef(null);
  const promptResolverRef = useRef(null);
  const locale = normalizeLocale(siteSettings["ui.locale"]);
  const t = useMemo(() => createTranslator(locale), [locale]);
  const tRef = useRef(t);

  useEffect(() => {
    tRef.current = t;
  }, [t]);

  const confirmAction = useCallback((options = {}) => {
    if (confirmResolverRef.current) {
      confirmResolverRef.current(false);
    }

    return new Promise((resolve) => {
      confirmResolverRef.current = resolve;
      setConfirmRequest({
        title: t("app.confirm_action"),
        message: "",
        confirmLabel: t("common.confirm"),
        cancelLabel: t("common.cancel"),
        tone: "default",
        ...options,
      });
    });
  }, [t]);

  const settleConfirm = useCallback((confirmed) => {
    const resolver = confirmResolverRef.current;
    confirmResolverRef.current = null;
    setConfirmRequest(null);
    resolver?.(confirmed);
  }, []);

  const promptAction = useCallback((options = {}) => {
    if (promptResolverRef.current) {
      promptResolverRef.current(null);
    }

    return new Promise((resolve) => {
      promptResolverRef.current = resolve;
      setPromptRequest({
        title: t("app.enter_value"),
        label: t("app.value"),
        message: "",
        initialValue: "",
        confirmLabel: t("common.save"),
        cancelLabel: t("common.cancel"),
        required: true,
        trimValue: true,
        ...options,
      });
    });
  }, [t]);

  const settlePrompt = useCallback((value) => {
    const resolver = promptResolverRef.current;
    promptResolverRef.current = null;
    setPromptRequest(null);
    resolver?.(value);
  }, []);

  useEffect(() => {
    currentThreadIdRef.current = currentThreadId;
  }, [currentThreadId]);

  useEffect(() => {
    return () => {
      confirmResolverRef.current?.(false);
      confirmResolverRef.current = null;
      promptResolverRef.current?.(null);
      promptResolverRef.current = null;
    };
  }, []);

  useEffect(() => {
    draftThreadProjectIdRef.current = draftThreadProjectId;
  }, [draftThreadProjectId]);

  useEffect(() => {
    projectIdRef.current = project?.id || null;
  }, [project?.id]);

  useEffect(() => {
    projectSqliteInfoProjectIdRef.current = projectSqliteInfoProjectId;
  }, [projectSqliteInfoProjectId]);

  useEffect(() => {
    showProjectDbInfoDialogRef.current = showProjectDbInfoDialog;
  }, [showProjectDbInfoDialog]);

  useEffect(() => {
    itemsRef.current = items;
  }, [items]);

  useEffect(() => {
    boardItemsRef.current = boardItems;
  }, [boardItems]);

  useEffect(() => {
    messagePagingRef.current = messagePaging;
  }, [messagePaging]);

  useEffect(() => {
    runningTurnsRef.current = runningTurns;
  }, [runningTurns]);

  useEffect(() => {
    if (Object.keys(runningTurns).length === 0) {
      setAgentThinking({ step: 0, lastAt: null });
    }
  }, [runningTurns]);

  function replaceBoardItems(nextItems, options = {}) {
    const items = nextItems || [];
    if (options.markLoaded !== false) boardItemsLoadedRef.current = true;
    boardItemsRef.current = items;
    setBoardItems(items);
  }

  function updateBoardItemsState(updater) {
    const nextItems =
      typeof updater === "function" ? updater(boardItemsRef.current) : updater;
    replaceBoardItems(nextItems);
    return nextItems;
  }

  function updateBoardHistory(updater) {
    const next = updater(boardHistoryRef.current);
    boardHistoryRef.current = next;
    setBoardHistory(next);
  }

  function clearBoardHistory() {
    updateBoardHistory(() => emptyBoardHistory());
  }

  function pushBoardHistoryEntry(entry) {
    if (!entry) return;

    updateBoardHistory((current) => ({
      ...current,
      undoStack: [...current.undoStack, entry].slice(-BOARD_HISTORY_LIMIT),
      redoStack: [],
    }));
  }

  useEffect(() => {
    return () => {
      revokePendingReferencePreviews(pendingReferencePreviewsRef.current);
    };
  }, []);

  useEffect(() => {
    function handleKeyDown(event) {
      if (!isShortcutGuideShortcut(event)) return;
      if (shouldIgnoreGlobalShortcut(event)) return;

      event.preventDefault();
      setShowShortcutGuideDialog(true);
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
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
      replaceBoardItems(boardData.items || []);
      clearBoardHistory();
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

  useEffect(() => {
    if (!channel || linkedProjectOpenRef.current) return undefined;

    const linkedProjectPath = new URLSearchParams(window.location.search).get(
      "project_path",
    );
    if (!linkedProjectPath) return undefined;

    linkedProjectOpenRef.current = true;
    let cancelled = false;

    async function openLinkedProject() {
      setNotice("");
      setDraftProjectId(null);
      setPrompt("");
      setReferences([]);
      clearPendingReferences();

      try {
        const opened = await openProject(linkedProjectPath);
        if (cancelled) return;

        setProject(opened);
        setProjectPath(opened.folder_path || linkedProjectPath);
        setProjects((current) => mergeById([opened, ...current]));
        setSelectedBoardIds([]);
        if (opened.id) {
          setExpandedProjectIds((current) =>
            current.includes(opened.id) ? current : [opened.id, ...current],
          );
        }

        await refreshProjects();
        const selectedThreadId = await refreshAll(
          opened.current_thread_id,
          opened,
        );
        if (cancelled || !opened.id) return;

        const targetPath = buildProjectWorkspacePath(
          opened.id,
          selectedThreadId,
        );
        window.history.replaceState({}, "", targetPath);
        setRoutePath(window.location.pathname);
      } catch (error) {
        if (!cancelled) setNotice(error.message);
      }
    }

    openLinkedProject();

    return () => {
      cancelled = true;
    };
  }, [channel, refreshAll, refreshProjects]);

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
        updateBoardItemsState((current) =>
          current.filter((item) => nextAssetIds.has(item.asset_id)),
        );
      }
      if (event === "board:items") {
        const nextBoardItems = payload.items || [];
        const createdBoardItems = boardItemsLoadedRef.current
          ? newBoardItems(boardItemsRef.current, nextBoardItems)
          : [];

        replaceBoardItems(nextBoardItems);
        clearBoardHistory();

        if (createdBoardItems.length > 0) {
          const createdAssetIds = createdBoardItems.map((item) => item.asset_id).filter(Boolean);
          setSelectedBoardIds(createdBoardItems.map((item) => item.id));
          if (createdAssetIds.length > 0) {
            setBoardFocusRequest({
              assetIds: createdAssetIds,
              mode: "fit_if_outside",
              requestId: Date.now(),
            });
          }
        } else {
          setSelectedBoardIds((current) =>
            current.filter((id) =>
              nextBoardItems.some((item) => item.id === id),
            ),
          );
        }
      }
      if (event === "board:item:updated") {
        updateBoardItemsState((current) =>
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
      if (event === "agent:thinking_tick") {
        const activeTurn = runningTurnsRef.current[payload.thread_id];
        if (
          activeTurn?.turn_id &&
          payload.turn_id &&
          activeTurn.turn_id !== payload.turn_id
        )
          return;

        setAgentThinking((current) => ({
          step: (current.step + 1) % THINKING_DOT_COUNT,
          lastAt: Date.now(),
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
      if (event === "project:sqlite:maintenance_started") {
        setProjectSqliteMaintenanceByProject((current) => ({
          ...current,
          [payload.project_id]: {
            ...payload,
            status: payload.status || "running",
          },
        }));
      }
      if (event === "project:sqlite:maintenance_completed") {
        const completedProjectId = payload.project_id;
        const hasProjectDbInfo =
          showProjectDbInfoDialogRef.current &&
          projectSqliteInfoProjectIdRef.current === completedProjectId;
        setProjectSqliteMaintenanceByProject((current) => {
          if (!completedProjectId) return current;
          const next = { ...current };
          delete next[completedProjectId];
          return next;
        });

        if (hasProjectDbInfo) {
          refreshProjectSqliteInfo(completedProjectId);
        }

        if (payload.success === false) {
          const code = payload.details?.error_code || "project_sqlite_maintenance_failed";
          const message =
            payload.details?.error_message ||
            payload.message ||
            tRef.current("app.database_maintenance_failed");
          setNotice(`${code}: ${message}`);
        }
      }
      if (
        event === "error" &&
        belongsToCurrentThread(payload, currentThreadIdRef.current)
      ) {
        setNotice(payload.message || tRef.current("app.error_occurred"));
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
        if (!cancelled) console.warn("Unable to load Codex models", error);
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
    setSelectedDataProvider(null);
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
    const name = await promptAction({
      title: t("app.new_blank_project"),
      label: t("app.project_name"),
      initialValue: "Untitled Project",
      confirmLabel: t("app.create"),
      cancelLabel: t("common.cancel"),
    });
    if (!name) return;

    await createBlankProjectFromName(name);
  }

  async function createBlankProjectFromName(name) {
    setNotice("");
    setPrompt("");
    setReferences([]);
    setSelectedDataProvider(null);
    clearPendingReferences();

    try {
      const created = await createBlankProject(name);
      setProject(created);
      setProjects((current) => mergeById([created, ...current]));
      setProjectPath(created.folder_path || "");
      setDraftProjectId(created.id || null);
      setSelectedBoardIds([]);
      if (created.id) {
        setExpandedProjectIds((current) =>
          current.includes(created.id) ? current : [created.id, ...current],
        );
      }
      await refreshProjects();
      await refreshAll(null, created);
    } catch (error) {
      setNotice(error.message);
    }
  }

  useEffect(() => {
    if (!channel || emptyProjectPromptShownRef.current) return;
    if (project || projects.length > 0) return;
    if (promptRequest || confirmRequest) return;
    if (new URLSearchParams(window.location.search).get("project_path")) return;

    emptyProjectPromptShownRef.current = true;
    handleCreateBlankProject();
  }, [channel, project, projects.length, promptRequest, confirmRequest]);

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
    setSelectedDataProvider(null);
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
    const confirmed = await confirmAction({
      title: t("app.archive_project"),
      message: t("app.archive_project_message", { name: projectEntry.name }),
      confirmLabel: t("app.archive_project"),
      cancelLabel: t("common.cancel"),
    });
    if (!confirmed) return;
    setNotice("");

    try {
      const data = await channel.push("project:archive", {
        id: projectEntry.id,
      });
      applyProjectRemoval(projectEntry.id, data.project);
      setNotice(t("app.project_archived"));
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleRenameProject(projectEntry) {
    if (!channel || !projectEntry?.id) return;

    const name = await promptAction({
      title: t("app.rename_project"),
      label: t("app.project_name"),
      initialValue: projectEntry.name || "",
      confirmLabel: t("common.save"),
      cancelLabel: t("common.cancel"),
    });
    if (!name || name === projectEntry.name) return;

    setNotice("");

    try {
      const renamed = await channel.push("project:rename", {
        id: projectEntry.id,
        name,
      });

      setProjects((current) =>
        current.map((entry) =>
          entry.id === renamed.id ? { ...entry, ...renamed } : entry,
        ),
      );

      setProject((current) =>
        current?.id === renamed.id
          ? {
              ...current,
              ...renamed,
              current_thread_id: current.current_thread_id,
            }
          : current,
      );
      setNotice(t("app.project_renamed"));
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleArchiveProjectThreads(projectEntry) {
    if (!channel || !projectEntry?.id) return;
    const confirmed = await confirmAction({
      title: t("app.archive_threads"),
      message: t("app.archive_threads_message", { name: projectEntry.name }),
      confirmLabel: t("app.archive_threads"),
      cancelLabel: t("common.cancel"),
    });
    if (!confirmed) return;
    setNotice("");

    try {
      const data = await channel.push("threads:archive_all", {
        project_id: projectEntry.id,
      });
      const archivedCount = data.archived_count || 0;

      if (project?.id === projectEntry.id) {
        const activeProject = { ...project, current_thread_id: null };
        setProject(activeProject);
        setDraftProjectId(projectEntry.id);
        currentThreadIdRef.current = null;
        setCurrentThreadId(null);
        resetMessageWindow(null);
        setSelectedBoardIds([]);
        await refreshAll(null, activeProject);
      } else {
        await loadProjectThreads(projectEntry.id);
      }

      setNotice(
        archivedCount > 0
          ? t("app.threads_archived", { count: archivedCount })
          : t("app.no_threads_to_archive"),
      );
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleDeleteProject(projectEntry) {
    if (!channel || !projectEntry?.id) return;
    const confirmed = await confirmAction({
      title: t("app.delete_project_reference"),
      message: t("app.delete_project_reference_message", {
        name: projectEntry.name,
      }),
      confirmLabel: t("app.delete_project_reference"),
      cancelLabel: t("common.cancel"),
      tone: "danger",
    });
    if (!confirmed) return;
    setNotice("");

    try {
      const data = await channel.push("project:delete", {
        id: projectEntry.id,
      });
      applyProjectRemoval(projectEntry.id, data.project);
      setNotice(t("app.project_reference_deleted"));
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleShowProjectDbInfo(projectEntry) {
    if (!projectEntry?.id) return;

    setNotice("");
    setProjectSqliteInfo(null);
    setProjectSqliteInfoProjectId(projectEntry.id);
    setShowProjectDbInfoDialog(true);

    try {
      if (projectEntry.id !== project?.id) {
        await handleSelectProject(projectEntry.id);
      }

      await refreshProjectSqliteInfo(projectEntry.id);
    } catch (error) {
      setShowProjectDbInfoDialog(false);
      setNotice(error.message);
    }
  }

  async function refreshProjectSqliteInfo(projectId = projectSqliteInfoProjectId) {
    setProjectSqliteInfoLoading(true);

    try {
      const info = await fetchProjectSqliteInfo();
      setProjectSqliteInfo(info);
      setProjectSqliteInfoProjectId(info?.project_id || projectId || null);
      return info;
    } catch (error) {
      setNotice(error.message);
      throw error;
    } finally {
      setProjectSqliteInfoLoading(false);
    }
  }

  async function handleRunProjectSqliteMaintenance(action) {
    const activeProjectId = projectSqliteInfoProjectId || project?.id;
    if (!activeProjectId) return;

    setNotice("");
    setProjectSqliteMaintenanceByProject((current) => ({
      ...current,
      [activeProjectId]: {
        project_id: activeProjectId,
        action,
        status: "running",
      },
    }));

    try {
      const result = await runProjectSqliteMaintenance(action);

      if (result?.status === "completed") {
        setProjectSqliteMaintenanceByProject((current) => omitKey(current, activeProjectId));
        await refreshProjectSqliteInfo(activeProjectId);
        return;
      }

      setProjectSqliteMaintenanceByProject((current) => ({
        ...current,
        [activeProjectId]: {
          project_id: activeProjectId,
          action,
          job_id: result?.job_id,
          status: result?.status || "running",
        },
      }));
    } catch (error) {
      setProjectSqliteMaintenanceByProject((current) => omitKey(current, activeProjectId));
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
    boardItemsLoadedRef.current = false;
    replaceBoardItems([], { markLoaded: false });
    clearBoardHistory();
    setReferences([]);
    setSelectedDataProvider(null);
    setPrompt("");
    clearPendingReferences();
    setSelectedBoardIds([]);
    setBoardFocusRequest(null);
    setRunningTurns({});
    setRepairingThreads({});
    setStreamingByTurn({});
    setProjectSqliteInfo(null);
    setProjectSqliteInfoProjectId(null);
    setProjectSqliteMaintenanceByProject({});
    setShowProjectDbInfoDialog(false);
    setProjectSqliteInfoLoading(false);
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
      setSelectedDataProvider(null);
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
    setSelectedDataProvider(null);
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
    const title = await promptAction({
      title: t("app.rename_thread"),
      label: t("app.thread_title"),
      initialValue: thread.title || "",
      confirmLabel: t("common.save"),
      cancelLabel: t("common.cancel"),
    });
    if (!title || title === thread.title) return;
    await channel.push("thread:rename", { id: thread.id, title });
    await refreshAll(thread.id);
  }

  async function handleDeleteThread(id) {
    if (!channel) return;
    const confirmed = await confirmAction({
      title: t("app.archive_thread"),
      message: t("app.archive_thread_message"),
      confirmLabel: t("app.archive_thread"),
      cancelLabel: t("common.cancel"),
    });
    if (!confirmed) return;
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

  async function handleReorderProjects(orderedIds) {
    if (!channel || !Array.isArray(orderedIds) || orderedIds.length === 0) return;

    const previousProjects = [...projects];
    const nextProjects = reorderByIdList(projects, orderedIds);
    const previousProjectId = project?.id;
    const previousProject = project;

    setNotice("");
    setProjects(nextProjects);
    setProject(previousProjectId ? nextProjects.find((entry) => entry.id === previousProjectId) || previousProject : previousProject);

    try {
      const data = await channel.push("project:reorder", {
        ordered_ids: orderedIds,
      });

      if (data.items) {
        setProjects(data.items);
        if (project?.id) {
          const next = data.items.find((entry) => entry.id === project.id);
          if (next) setProject(next);
        }
      }
    } catch (error) {
      setProjects(previousProjects);
      setProject(previousProjectId
        ? previousProjects.find((entry) => entry.id === previousProjectId) || previousProject
        : previousProject);
      setNotice(error.message);
    }
  }

  async function handleReorderThreads(projectId, orderedIds) {
    if (!channel || !projectId || !Array.isArray(orderedIds) || orderedIds.length === 0)
      return;

    const previousThreads = threadsByProjectId[projectId] || [];
    const nextThreads = reorderByIdList(previousThreads, orderedIds);
    const previousThreadsForCurrent = project?.id === projectId ? threads : [];

    setThreadsByProjectId((current) => ({
      ...current,
      [projectId]: nextThreads,
    }));

    if (project?.id === projectId) {
      setThreads(nextThreads);
    }

    try {
      const data = await channel.push("thread:reorder", {
        project_id: projectId,
        ordered_ids: orderedIds,
      });

      if (data.items) {
        setThreadsByProjectId((current) => ({
          ...current,
          [projectId]: data.items,
        }));
        if (project?.id === projectId) {
          setThreads(data.items);
        }
      }
    } catch (error) {
      setThreadsByProjectId((current) => ({
        ...current,
        [projectId]: previousThreads,
      }));
      if (project?.id === projectId) {
        setThreads(previousThreadsForCurrent);
      }
      setNotice(error.message);
    }
  }

  async function handleSend() {
    if (!channel || !project) return;
    const text = prompt.trim();
    if (!text && references.length === 0) return;
    const messageText = appendImageSettingsToPrompt(text, imageSettings);
    if (hasUploadingReferences(pendingReferences)) {
      setNotice(t("app.wait_uploading"));
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
        ...dataProviderPayload(selectedDataProvider),
        ...settingsPayload(composerSettings),
      });

      if (data.thread) applyThreadUpdate(data.thread);
      setPrompt("");
      setReferences([]);
      setSelectedDataProvider(null);
      setImageSettings(defaultImageSettings(siteSettings));
      clearPendingReferences();
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleSendImagePrompt(assetId, text, maskFile = null) {
    if (!channel || !project) throw new Error(t("app.open_project_first"));

    const messageText = String(text || "").trim();
    if (!assetId || !messageText) return null;
    if (!assets.some((asset) => asset.id === assetId)) {
      throw new Error(t("app.image_unavailable"));
    }

    setNotice("");

    try {
      const maskAsset = maskFile ? await uploadMaskAsset(assetId, maskFile) : null;
      const thread = await createThreadForDraft();
      if (project?.id && thread?.id) {
        navigateToPath(buildProjectWorkspacePath(project.id, thread.id));
      }

      const data = await channel.push("message:send", {
        thread_id: thread.id,
        text: messageText,
        asset_ids: maskAsset ? [assetId, maskAsset.id] : [assetId],
        ...(maskAsset
          ? {
              mask_edit: {
                mode: "visual_reference",
                base_asset_id: assetId,
                mask_asset_id: maskAsset.id,
                mask_semantics: "white_edit_black_keep",
              },
            }
          : {}),
        ...settingsPayload(composerSettings),
      });

      if (data.thread) applyThreadUpdate(data.thread);
      if (maskAsset) await refreshAssetsAndBoard();
      return data;
    } catch (error) {
      setNotice(error.message);
      throw error;
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

  function messageHasFollowingContent(item) {
    if (!item?.id) return false;

    const visibleItems = itemsRef.current || [];
    const index = visibleItems.findIndex((candidate) => candidate.id === item.id);

    if (index < 0) return true;
    return index < visibleItems.length - 1 || messagePagingRef.current.hasMoreAfter;
  }

  async function handleUpdateItem(item, content) {
    if (!channel || !item?.id) return false;
    setNotice("");

    try {
      const isUserMessage = item.type === "user_message" || item.role === "user";

      if (isUserMessage && messageHasFollowingContent(item)) {
        const confirmed = await confirmAction({
          title: t("chat.edit_rerun_title"),
          message: t("chat.edit_rerun_message"),
          confirmLabel: t("chat.save_and_rerun"),
          tone: "danger",
        });

        if (!confirmed) return false;
      }

      const data = isUserMessage
        ? await channel.push("message:edit_rerun", {
            item_id: item.id,
            content,
          })
        : await channel.push("item:update", {
            id: item.id,
            content,
          });

      if (data.item) mergeUpdatedMessageItem(data.item);
      if (data.turn) markTurnStatus(data.turn.id, data.turn.status);
      return true;
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
      const data = await channel.push(
        "thread:repair",
        {
          thread_id: repairThreadId,
        },
        30_000,
      );
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
      replaceBoardItems(nextBoardItems);
      clearBoardHistory();
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
        t("app.thread_repaired", {
          turns: repair.matched_turns || 0,
          items: repair.synced_items || 0,
        }),
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
      setNotice(t("app.open_project_first"));
      return;
    }

    for (const file of files) {
      await uploadReferenceFile(file);
    }
  }

  async function uploadReferenceFile(file) {
    if (!file) return false;

    if (!project) {
      setNotice(t("app.open_project_first"));
      return false;
    }

    if (!isSupportedReferenceImage(file)) {
      setNotice(t("app.unsupported_image"));
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
    replaceBoardItems(boardData.items || []);
    clearBoardHistory();
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
    const asset = assets.find((candidate) => candidate.id === assetId);

    if (boardItem || isWorkAsset(asset)) {
      setSelectedBoardIds(boardItem ? [boardItem.id] : []);
      setBoardFocusRequest({ assetId, requestId: Date.now() });
      setNotice("");

      if (window.matchMedia("(max-width: 760px)").matches) {
        setMobileView("board");
      } else if (window.matchMedia("(max-width: 1080px)").matches) {
        setCollapsedLeftAndMiddle(true);
      }

      return;
    }

    addReference(assetId);
    setNotice(t("app.image_added_reference"));
  }

  async function handleResize(id, displayWidth, displayHeight, commit) {
    if (commit) {
      return handleUpdateBoardItems(
        [
          {
            id,
            display_width: displayWidth,
            display_height: displayHeight,
          },
        ],
        true,
        { historyLabel: "Resize" },
      );
    }

    updateBoardItemsState((current) =>
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

    return { ok: true };
  }

  async function handleUpdateBoardItems(updates, commit, options = {}) {
    const itemUpdates = Array.isArray(updates) ? updates.filter(Boolean) : [];
    if (!itemUpdates.length) return { ok: false };

    const beforeSnapshots =
      commit && channel && !options.skipHistory
        ? boardHistorySnapshotsForUpdates(
            boardItemsRef.current,
            itemUpdates,
            options.beforeSnapshot,
          )
        : [];

    replaceBoardItems(mergeBoardItemUpdates(boardItemsRef.current, itemUpdates));

    if (!commit) return { ok: true, items: boardItemsRef.current };
    if (!channel) return { ok: false };

    try {
      const data = await channel.push("board:items:update", {
        items: itemUpdates,
      });

      if (data.items?.length) {
        replaceBoardItems(
          mergeBoardItemReplacements(boardItemsRef.current, data.items),
        );
      }

      if (!options.skipHistory && beforeSnapshots.length > 0) {
        const afterSnapshots = boardHistorySnapshotsForIds(
          boardItemsRef.current,
          beforeSnapshots.map((snapshot) => snapshot.id),
        );
        pushBoardHistoryEntry(
          createBoardHistoryEntry(
            options.historyLabel || "Board update",
            beforeSnapshots,
            afterSnapshots,
          ),
        );
      }

      options.afterSuccess?.(data);
      return { ok: true, data, items: boardItemsRef.current };
    } catch (error) {
      setNotice(error.message);
      await refreshAssetsAndBoard();
      return { ok: false, error };
    }
  }

  async function handleUndoBoardHistory() {
    await performBoardHistoryAction("undo");
  }

  async function handleRedoBoardHistory() {
    await performBoardHistoryAction("redo");
  }

  async function performBoardHistoryAction(direction) {
    if (boardHistoryRef.current.busy) return;

    updateBoardHistory((current) => ({ ...current, busy: true }));

    try {
      while (true) {
        const history = boardHistoryRef.current;
        const sourceStack =
          direction === "undo" ? history.undoStack : history.redoStack;
        const entry = sourceStack[sourceStack.length - 1];
        if (!entry) return;

        const targetSnapshots =
          direction === "undo" ? entry.before : entry.after;
        const target = boardHistoryTargetUpdates(
          boardItemsRef.current,
          targetSnapshots,
        );

        if (target.existingCount === 0) {
          updateBoardHistory((current) =>
            removeBoardHistoryEntry(current, direction, entry.id),
          );
          continue;
        }

        if (target.updates.length > 0) {
          const result = await handleUpdateBoardItems(target.updates, true, {
            skipHistory: true,
          });
          if (!result.ok) return;
        }

        updateBoardHistory((current) =>
          moveBoardHistoryEntry(current, direction, entry),
        );
        return;
      }
    } finally {
      updateBoardHistory((current) => ({ ...current, busy: false }));
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
      setNotice(t("app.path_copied"));
    } catch (error) {
      setNotice(error.message);
    }
  }

  async function handleDeleteSelectedBoardItem({ item, selectedCount } = {}) {
    if (selectedCount !== 1 || !item) {
      setNotice(t("app.delete_one_file_only"));
      return;
    }

    const asset = assets.find((candidate) => candidate.id === item.asset_id);
    const fileName = asset?.file_name || item.file_name || t("common.image");

    const confirmed = await confirmAction({
      title: t("app.delete_image"),
      message: t("app.delete_image_message", { name: fileName }),
      confirmLabel: t("app.delete_image"),
      cancelLabel: t("common.cancel"),
      tone: "danger",
    });
    if (!confirmed) return;

    setNotice("");

    try {
      await deleteAsset(item.asset_id);
      setReferences((current) => current.filter((id) => id !== item.asset_id));
      setSelectedBoardIds((current) => current.filter((id) => id !== item.id));
      updateBoardItemsState((current) =>
        current.filter(
          (candidate) =>
            candidate.id !== item.id && candidate.asset_id !== item.asset_id,
        ),
      );
      setAssets((current) =>
        current.filter((candidate) => candidate.id !== item.asset_id),
      );
      await refreshAssetsAndBoard();
      setNotice(t("app.image_deleted"));
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
    const threadId =
      draftThreadProjectId === project.id ? null : currentThreadId;
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
    if (
      !project?.id ||
      tracingThreadId ||
      settingsRoute ||
      isProjectRouteSyncRef.current
    )
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
  const projectDbInfoProject = useMemo(() => {
    if (!projectSqliteInfoProjectId) return project;
    return (
      projects.find((entry) => entry.id === projectSqliteInfoProjectId) ||
      (project?.id === projectSqliteInfoProjectId ? project : null)
    );
  }, [project, projects, projectSqliteInfoProjectId]);
  const streamingText = activeRun
    ? streamingByTurn[activeRun.turn_id]?.text || ""
    : "";
  const nextUndoEntry = boardHistory.undoStack[boardHistory.undoStack.length - 1];
  const nextRedoEntry = boardHistory.redoStack[boardHistory.redoStack.length - 1];
  const confirmDialog = confirmRequest ? (
    <ConfirmDialog
      {...confirmRequest}
      t={t}
      onCancel={() => settleConfirm(false)}
      onConfirm={() => settleConfirm(true)}
    />
  ) : null;
  const promptDialog = promptRequest ? (
    <PromptDialog
      {...promptRequest}
      t={t}
      onCancel={() => settlePrompt(null)}
      onConfirm={(value) => settlePrompt(value)}
    />
  ) : null;

  if (tracingThreadId) {
    return (
      <>
        <TracingPage
          channel={channel}
          connectionState={connectionState}
          project={project}
          threadId={tracingThreadId}
          threads={threads}
          onBack={() => navigateToPath("/web")}
        />
        {confirmDialog}
        {promptDialog}
      </>
    );
  }

  if (settingsRoute) {
    return (
      <>
        <SettingsPage
          settingsItems={siteSettingItems}
          settings={siteSettings}
          modelOptions={modelOptions}
          connectionState={connectionState}
          t={t}
          onSave={handleSaveSiteSettings}
          onReset={handleResetSiteSettings}
          onBack={handleCloseSettings}
          onConfirm={confirmAction}
        />
        {confirmDialog}
        {promptDialog}
      </>
    );
  }

  return (
    <>
      <nav className="mobile-tabs" aria-label={t("app.workspace_views", {}, "Workspace views")}>
        {[
          ["project", "common.project"],
          ["thread", "common.thread"],
          ["board", "common.board"],
        ].map(([value, labelKey]) => (
          <button
            className={mobileView === value ? "active" : ""}
            type="button"
            key={value}
            onClick={() => setMobileView(value)}
          >
            {t(labelKey)}
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
          onRenameProject={handleRenameProject}
          onRenameThread={handleRenameThread}
          onDeleteThread={handleDeleteThread}
          onArchiveProject={handleArchiveProject}
          onArchiveProjectThreads={handleArchiveProjectThreads}
          onDeleteProject={handleDeleteProject}
          onReorderProjects={handleReorderProjects}
          onReorderThreads={handleReorderThreads}
          onShowProjectDbInfo={handleShowProjectDbInfo}
          onOpenSettings={handleOpenSettings}
          connectionState={connectionState}
          agentRunning={anyAgentRunning}
          agentThinkingStep={agentThinking.step}
          runningThreadIds={runningThreadIds}
          t={t}
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
              selectedDataProvider={selectedDataProvider}
              defaultImageSettings={defaultImageSettings(siteSettings)}
              onComposerSettingsChange={handleComposerSettingsChange}
              onImageSettingsChange={(patch) =>
                setImageSettings((current) => ({ ...current, ...patch }))
              }
              onDataProviderChange={setSelectedDataProvider}
              onApprovalRespond={handleApprovalRespond}
              onUpdateItem={handleUpdateItem}
              onLoadEarlier={handleLoadEarlierItems}
              onReturnToLatest={handleReturnToLatestItems}
              onLoadAroundTurn={handleLoadAroundTurn}
              onBottomStateChange={handleMessageBottomChange}
              t={t}
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
              onSendImagePrompt={handleSendImagePrompt}
              onReveal={handleReveal}
              onCopyPath={handleCopyPath}
              onDeleteSelected={handleDeleteSelectedBoardItem}
              collapsedLeftAndMiddle={collapsedLeftAndMiddle}
              onOpenShortcuts={() => setShowShortcutGuideDialog(true)}
              onToggleLeftAndMiddle={() =>
                setCollapsedLeftAndMiddle((value) => !value)
              }
              canUndo={boardHistory.undoStack.length > 0}
              canRedo={boardHistory.redoStack.length > 0}
              undoLabel={nextUndoEntry?.label}
              redoLabel={nextRedoEntry?.label}
              historyBusy={boardHistory.busy}
              onUndo={handleUndoBoardHistory}
              onRedo={handleRedoBoardHistory}
              onConfirm={confirmAction}
              t={t}
            />
          </div>
        </section>

        {notice ? (
          <div className="notice" role="status">
            <span>{notice}</span>
            <button type="button" onClick={() => setNotice("")}>
              {t("app.dismiss")}
            </button>
          </div>
        ) : null}
      </div>

      {showProjectDbInfoDialog ? (
        <ProjectDbInfoDialog
          info={projectSqliteInfo}
          projectName={projectDbInfoProject?.name}
          maintenance={projectSqliteMaintenanceByProject[projectSqliteInfoProjectId]}
          isLoading={projectSqliteInfoLoading}
          onClose={() => setShowProjectDbInfoDialog(false)}
          onRefresh={() => refreshProjectSqliteInfo(projectSqliteInfoProjectId)}
          onRunMaintenance={handleRunProjectSqliteMaintenance}
        />
      ) : null}
      {showShortcutGuideDialog ? (
        <ShortcutGuideDialog
          onClose={() => setShowShortcutGuideDialog(false)}
          t={t}
        />
      ) : null}
      {confirmDialog}
      {promptDialog}
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

function newBoardItems(previousItems, nextItems) {
  const previousIds = new Set(
    (previousItems || []).map((item) => item.id).filter(Boolean),
  );
  return (nextItems || []).filter((item) => item?.id && !previousIds.has(item.id));
}

function reorderByIdList(items, orderedIds) {
  const source = items || [];
  const order = orderedIds || [];
  const byId = new Map(source.map((item) => [item.id, item]));
  const next = [];
  const used = new Set();

  order.forEach((id) => {
    const entry = byId.get(id);
    if (!entry || used.has(id)) return;
    used.add(id);
    next.push(entry);
  });

  source.forEach((item) => {
    if (!used.has(item.id)) next.push(item);
  });

  return next;
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

function isWorkAsset(asset) {
  return (
    asset?.source !== "mask" &&
    typeof asset?.relative_path === "string" &&
    asset.relative_path.startsWith("work/")
  );
}

function revokePendingReferencePreviews(previews) {
  previews.forEach((previewUrl) => URL.revokeObjectURL(previewUrl));
  previews.clear();
}

function emptyBoardHistory() {
  return {
    undoStack: [],
    redoStack: [],
    busy: false,
  };
}

function mergeBoardItemUpdates(items, updates) {
  const updateById = new Map(updates.map((update) => [update.id, update]));

  return items.map((item) => ({
    ...item,
    ...(updateById.get(item.id) || {}),
  }));
}

function mergeBoardItemReplacements(items, updatedItems) {
  const updatedById = new Map(updatedItems.map((item) => [item.id, item]));

  return items.map((item) => updatedById.get(item.id) || item);
}

function boardHistorySnapshotsForUpdates(items, updates, beforeSnapshot = []) {
  const itemById = new Map(items.map((item) => [item.id, item]));
  const beforeById = new Map(
    (beforeSnapshot || []).map((snapshot) => [snapshot.id, snapshot]),
  );

  return updates
    .map((update) => {
      const currentItem = itemById.get(update.id);
      if (!currentItem) return null;

      return boardItemHistorySnapshot(
        beforeById.get(update.id) || {},
        currentItem,
      );
    })
    .filter(Boolean);
}

function boardHistorySnapshotsForIds(items, ids) {
  const itemById = new Map(items.map((item) => [item.id, item]));

  return ids
    .map((id) => {
      const item = itemById.get(id);
      return item ? boardItemHistorySnapshot(item) : null;
    })
    .filter(Boolean);
}

function createBoardHistoryEntry(label, beforeSnapshots, afterSnapshots) {
  const afterById = new Map(afterSnapshots.map((snapshot) => [snapshot.id, snapshot]));
  const before = [];
  const after = [];

  beforeSnapshots.forEach((beforeSnapshot) => {
    const afterSnapshot = afterById.get(beforeSnapshot.id);
    if (!afterSnapshot || boardHistorySnapshotsEqual(beforeSnapshot, afterSnapshot)) {
      return;
    }

    before.push(beforeSnapshot);
    after.push(afterSnapshot);
  });

  if (before.length === 0) return null;

  return {
    id: `board-history-${Date.now()}-${Math.random().toString(36).slice(2)}`,
    label,
    before,
    after,
  };
}

function boardHistoryTargetUpdates(items, snapshots) {
  const itemById = new Map(items.map((item) => [item.id, item]));
  let existingCount = 0;

  const updates = snapshots.filter((snapshot) => {
    const item = itemById.get(snapshot.id);
    if (!item) return false;
    existingCount += 1;
    return !boardHistorySnapshotsEqual(boardItemHistorySnapshot(item), snapshot);
  });

  return { existingCount, updates };
}

function removeBoardHistoryEntry(history, direction, entryId) {
  const sourceKey = direction === "undo" ? "undoStack" : "redoStack";

  return {
    ...history,
    [sourceKey]: history[sourceKey].filter((entry) => entry.id !== entryId),
  };
}

function moveBoardHistoryEntry(history, direction, entry) {
  const sourceKey = direction === "undo" ? "undoStack" : "redoStack";
  const targetKey = direction === "undo" ? "redoStack" : "undoStack";

  return {
    ...history,
    [sourceKey]: history[sourceKey].filter((candidate) => candidate.id !== entry.id),
    [targetKey]: [...history[targetKey], entry].slice(-BOARD_HISTORY_LIMIT),
  };
}

function boardItemHistorySnapshot(item, fallback = {}) {
  return {
    id: historyFieldValue(item, fallback, "id"),
    x: historyNumber(historyFieldValue(item, fallback, "x")),
    y: historyNumber(historyFieldValue(item, fallback, "y")),
    display_width: historyNumber(
      historyFieldValue(item, fallback, "display_width"),
    ),
    display_height: historyNumber(
      historyFieldValue(item, fallback, "display_height"),
    ),
    z_index: historyPositiveInteger(
      historyFieldValue(item, fallback, "z_index"),
    ),
  };
}

function boardHistorySnapshotsEqual(left, right) {
  return BOARD_HISTORY_FIELDS.every((field) => left[field] === right[field]);
}

function historyFieldValue(item, fallback, field) {
  if (item && Object.prototype.hasOwnProperty.call(item, field)) {
    return item[field];
  }

  return fallback?.[field];
}

function historyNumber(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return 0;
  return Math.round((number + Number.EPSILON) * 1000) / 1000;
}

function historyPositiveInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : 1;
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

function dataProviderPayload(provider) {
  if (!provider?.slug) return {};

  return {
    data_provider: {
      slug: provider.slug,
      name: provider.name,
      version: provider.version || null,
      loaded: provider.loaded === true,
    },
  };
}

function normalizeSiteSettings(settings = {}) {
  const merged = {
    ...DEFAULT_SITE_SETTINGS,
    ...(settings || {}),
  };

  return {
    ...merged,
    "ui.locale": normalizeLocale(merged["ui.locale"]),
  };
}
