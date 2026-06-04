import { useRef } from "react";
import { Database, RefreshCw, X } from "lucide-react";
import IconButton from "../../components/IconButton.jsx";
import { useModalDialog } from "../../components/useModalDialog.js";

export default function ProjectDbInfoDialog({
  info,
  projectName,
  maintenance,
  isLoading = false,
  onClose,
  onRefresh,
  onRunMaintenance,
}) {
  const closeButtonRef = useRef(null);
  const dialogRef = useModalDialog({
    onCancel: onClose,
    initialFocusRef: closeButtonRef,
  });

  const sqliteInfo = info?.sqlite_info || {};
  const tableRows = info?.table_rows || [];
  const isUnavailable = !info?.exists || info?.status !== "available";
  const runningAction = maintenance?.action;
  const runningJobId = maintenance?.job_id;
  const runningStatus = maintenance?.status;
  const isRunning =
    runningStatus === "queued" ||
    runningStatus === "running" ||
    runningAction === "deep_vacuum";
  const isBusy = isLoading || isRunning;

  function handleRun(action) {
    if (isBusy) return;
    onRunMaintenance?.(action);
  }

  function closeOnBackdrop(event) {
    if (event.target === event.currentTarget) onClose();
  }

  return (
    <section className="project-db-info-backdrop" onMouseDown={closeOnBackdrop}>
      <div
        className="project-db-info-dialog"
        role="dialog"
        aria-modal="true"
        aria-label="Project sqlite information"
        ref={dialogRef}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="project-db-info-header">
          <div className="project-db-info-title">
            <span className="project-db-info-title-icon">
              <Database size={16} />
            </span>
            <div>
              <strong title={projectName || "Project"}>{projectName || "Project"}</strong>
              <small>项目数据库情况</small>
            </div>
          </div>
          <div className="project-db-info-actions-inline">
            <IconButton
              label="Refresh"
              className="ghost"
              onClick={onRefresh}
              disabled={isLoading}
            >
              <RefreshCw size={16} />
            </IconButton>
            <IconButton
              label="Close"
              className="ghost"
              onClick={onClose}
              ref={closeButtonRef}
            >
              <X size={16} />
            </IconButton>
          </div>
        </header>

        <section className="project-db-info-metrics">
          <h3>关键指标</h3>
          <dl>
            <div>
              <dt>路径</dt>
              <dd>{info?.db_path || "—"}</dd>
            </div>
            <div>
              <dt>可用性</dt>
              <dd>{isUnavailable ? (info?.status || "unavailable") : "available"}</dd>
            </div>
            <div>
              <dt>文件大小</dt>
              <dd>{formatBytes(info?.size_bytes)}</dd>
            </div>
            <div>
              <dt>文件修改时间</dt>
              <dd>{formatDateTime(info?.file_mtime)}</dd>
            </div>
            <div>
              <dt>页面大小</dt>
              <dd>{numberOrDash(sqliteInfo.page_size)}</dd>
            </div>
            <div>
              <dt>空闲页</dt>
              <dd>{numberOrDash(sqliteInfo.freelist_count)}</dd>
            </div>
            <div>
              <dt>Journal Mode</dt>
              <dd>{sqliteInfo.journal_mode || "—"}</dd>
            </div>
            <div>
              <dt>Schema Version</dt>
              <dd>{sqliteInfo.schema_version || "—"}</dd>
            </div>
            <div>
              <dt>最近优化时间</dt>
              <dd>{formatDateTime(info?.optimized_at)}</dd>
            </div>
          </dl>
        </section>

        <section className="project-db-info-tables">
          <h3>表行数</h3>
          {tableRows.length > 0 ? (
            <div className="project-db-table-grid">
              {tableRows.map((entry) => (
                <div key={entry.name} className="project-db-table-row">
                  <span>{entry.name}</span>
                  <strong>{numberOrDash(entry.rows)}</strong>
                </div>
              ))}
            </div>
          ) : (
            <p className="project-db-empty">没有可用表统计。</p>
          )}
        </section>

        <section className="project-db-info-actions-area">
          <h3>数据库维护</h3>
          <div className="project-db-buttons">
            <button
              type="button"
              className="primary"
              onClick={() => handleRun("fast_optimize")}
              disabled={isBusy || isUnavailable}
            >
              快速优化（fast_optimize）
            </button>
            <button
              type="button"
              onClick={() => handleRun("deep_vacuum")}
              disabled={isBusy || isUnavailable}
            >
              深度整理（deep_vacuum）
            </button>
          </div>

          <div className="project-db-info-explainer">
            <p>
              1. 快速优化（fast_optimize）：执行 <code>PRAGMA wal_checkpoint(TRUNCATE)</code> +{" "}
              <code>PRAGMA optimize</code>。
            </p>
            <p>
              2. 深度整理（deep_vacuum）：执行 <code>VACUUM</code>。
            </p>
          </div>

          {isBusy ? (
            <p className="project-db-info-state">
              维护中：{runningAction === "deep_vacuum" ? "deep_vacuum" : "fast_optimize"}
              {runningJobId ? `（任务 ${runningJobId}）` : ""}
            </p>
          ) : null}
          <p className="project-db-info-note">
            当前后端不支持中止深度整理，深度任务会在完成后自动返回结果。
          </p>
        </section>
      </div>
    </section>
  );
}

function formatDateTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString();
}

function formatBytes(value) {
  const bytes = Number(value || 0);
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let remaining = bytes;
  let index = 0;

  while (remaining >= 1024 && index < units.length - 1) {
    remaining /= 1024;
    index += 1;
  }

  const precision = remaining < 10 ? 2 : 1;
  return `${remaining.toFixed(precision)} ${units[index]}`;
}

function numberOrDash(value) {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "number" && Number.isNaN(value)) return "—";
  return String(value);
}
