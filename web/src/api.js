async function request(path, options = {}) {
  const response = await fetch(path, options);
  const contentType = response.headers.get("content-type") || "";
  const payload = contentType.includes("application/json") ? await response.json() : null;

  if (!response.ok || payload?.success === false) {
    const message = payload?.error?.message || `Request failed: ${response.status}`;
    throw new Error(message);
  }

  return payload?.data;
}

export function openProject(path) {
  return request("/api/project/open", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path }),
  });
}

export function createBlankProject(name) {
  return request("/api/project/create_blank", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ name }),
  });
}

export function importAsset(path) {
  return request("/api/assets/import", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ path }),
  });
}

export function scanAssets() {
  return request("/api/assets/scan", { method: "POST" });
}

export function uploadAsset(file) {
  const body = new FormData();
  body.append("file", file);
  return request("/api/assets/upload", { method: "POST", body });
}

export function uploadMaskAsset(baseAssetId, file) {
  const body = new FormData();
  body.append("base_asset_id", baseAssetId);
  body.append("file", file);
  return request("/api/assets/mask", { method: "POST", body });
}

export function revealAsset(id) {
  return request(`/api/assets/${id}/reveal`, { method: "POST" });
}

export function readAssetPath(id) {
  return request(`/api/assets/${id}/path`);
}

export function deleteAsset(id) {
  return request(`/api/assets/${id}`, { method: "DELETE" });
}

export function previewUrl(asset) {
  return `/api/assets/${asset.id}/preview?v=${encodeURIComponent(asset.updated_at || "")}`;
}

export function projectSqliteInfo() {
  return request("/api/project/sqlite_info");
}

export function projectSqliteMaintenance(action) {
  return request("/api/project/sqlite_maintenance", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ action }),
  });
}
