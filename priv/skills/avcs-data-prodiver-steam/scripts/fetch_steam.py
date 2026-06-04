#!/usr/bin/env python3
"""Fetch Steam game metadata and cover images by game name."""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


STEAM_STORESEARCH_API = "https://store.steampowered.com/api/storesearch/"
STEAM_APPDETAILS_API = "https://store.steampowered.com/api/appdetails/"
_STEAM_APP_URL = "https://store.steampowered.com/app/{appid}/"
_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tif", ".tiff"}


class SteamError(RuntimeError):
    pass


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Fetch Steam game metadata and covers")
    parser.add_argument("--game", required=True, help="Game name or keyword")
    parser.add_argument("--lang", default="en-us", help="Steam API language code (default: en-us)")
    parser.add_argument("--cc", default="US", help="Steam country code (default: US)")
    parser.add_argument(
        "--cover-key",
        default="header_image",
        choices=["header_image", "capsule_image", "capsule_imagev5", "any", "last"],
        help="Prefer cover image key in appdetails payload",
    )
    parser.add_argument(
        "--select-index",
        type=int,
        default=0,
        help="Index in storesearch result list (default: 0)",
    )
    parser.add_argument(
        "--out-dir",
        default=str(Path.cwd() / "work"),
        help="Directory to save downloaded cover",
    )
    return parser.parse_args()


def _http_get(url: str) -> Tuple[bytes, str]:
    req = Request(
        url,
        headers={
            "User-Agent": "avcs-data-prodiver-steam",
            "Accept": "application/json,text/plain,*/*;q=0.8",
        },
    )
    try:
        with urlopen(req, timeout=30) as response:
            return response.read(), response.headers.get("Content-Type", "")
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        raise SteamError(f"HTTP {exc.code} while requesting {url}: {body}") from exc
    except URLError as exc:
        raise SteamError(f"Network error while requesting {url}: {exc}") from exc


def _http_get_json(url: str) -> Dict[str, Any]:
    payload_bytes, _ = _http_get(url)
    payload = json.loads(payload_bytes.decode("utf-8"))
    if not isinstance(payload, dict):
        raise SteamError("Steam response is not a JSON object")
    return payload


def _safe_json_print(payload: Dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def _to_int(value: Any) -> Optional[int]:
    if isinstance(value, bool) or value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _slugify(value: str, max_len: int = 40) -> str:
    safe = [
        ch.lower() if ch.isalnum() or ch in "._-" else "-" for ch in value.strip().replace(" ", "-")
    ]
    slug = "".join(safe).strip("-._")
    slug = re.sub(r"-+", "-", slug)
    if not slug:
        slug = "steam-game"
    if len(slug) <= max_len:
        return slug
    return slug[:max_len].rstrip("-._")


def _guess_suffix(url: str) -> str:
    path = url.split("?", 1)[0].split("#", 1)[0]
    suffix = Path(path).suffix.lower()
    return suffix if suffix in _IMAGE_EXTENSIONS else ".jpg"


def _normalize_url(url: Any) -> Optional[str]:
    if not isinstance(url, str):
        return None
    value = url.strip()
    return value or None


def _build_storesearch_url(game: str, lang: str, cc: str) -> str:
    return f"{STEAM_STORESEARCH_API}?{urlencode({'term': game, 'cc': cc, 'l': lang, 'count': '50'})}"


def _build_appdetails_url(appid: int, lang: str, cc: str) -> str:
    return f"{STEAM_APPDETAILS_API}?{urlencode({'appids': str(appid), 'l': lang, 'cc': cc})}"


def _search_game(game: str, lang: str, cc: str, select_index: int) -> Tuple[Dict[str, Any], str]:
    search_url = _build_storesearch_url(game, lang, cc)
    payload = _http_get_json(search_url)

    items = payload.get("items")
    if not isinstance(items, list) or not items:
        return payload, "no_results"

    if select_index < 0 or select_index >= len(items):
        raise SteamError(
            f"select_index {select_index} out of range. Search returned {len(items)} items."
        )

    return {"storesearch": payload, "selected": items[select_index]}, "found"


def _extract_appid(item: Dict[str, Any]) -> Optional[int]:
    if not isinstance(item, dict):
        return None
    return _to_int(item.get("id")) or _to_int(item.get("appid")) or _to_int(item.get("steam_appid"))


def _fetch_appdetails(appid: int, lang: str, cc: str) -> Dict[str, Any]:
    details_url = _build_appdetails_url(appid, lang, cc)
    payload = _http_get_json(details_url)

    app_payload = payload.get(str(appid)) or payload.get(appid)
    if not isinstance(app_payload, dict):
        raise SteamError(f"appdetails missing payload for appid {appid}")
    if not app_payload.get("success"):
        raise SteamError(f"appdetails reports failure for appid {appid}")

    data = app_payload.get("data")
    if not isinstance(data, dict):
        raise SteamError(f"appdetails data invalid for appid {appid}")

    return {
        "appid": appid,
        "data": data,
        "url": details_url,
    }


def _collect_covers(data: Dict[str, Any]) -> Dict[str, str]:
    base_fields = [
        "header_image",
        "capsule_image",
        "capsule_imagev5",
        "small_capsule",
        "large_capsule",
        "small_logo",
    ]

    covers: Dict[str, str] = {}
    for key in base_fields:
        value = _normalize_url(data.get(key))
        if value:
            covers[key] = value

    screenshots = data.get("screenshots")
    if isinstance(screenshots, list):
        for index, item in enumerate(screenshots):
            if not isinstance(item, dict):
                continue
            thumb = _normalize_url(item.get("path_thumbnail"))
            full = _normalize_url(item.get("path_full"))
            if thumb:
                covers[f"screenshot_{index:02d}_thumbnail"] = thumb
            if full:
                covers[f"screenshot_{index:02d}_full"] = full

    return covers


def _pick_cover(covers: Dict[str, str], prefer_key: str) -> Tuple[str, Optional[str]]:
    if prefer_key == "last" and covers:
        key = list(covers.keys())[-1]
        return key, covers[key]

    if prefer_key != "any" and prefer_key in covers:
        return prefer_key, covers[prefer_key]

    for key in ["header_image", "capsule_imagev5", "capsule_image", "small_capsule", "large_capsule"]:
        if key in covers:
            return key, covers[key]

    if covers:
        key = next(iter(covers))
        return key, covers[key]

    return "", None


def _download_image(url: str, out_dir: Path, slug: str, appid: int, cover_key: str) -> Path:
    data, _ = _http_get(url)
    out_dir.mkdir(parents=True, exist_ok=True)
    filename = f"steam-{appid}-{slug}-{cover_key}{_guess_suffix(url)}"
    path = out_dir / filename
    path.write_bytes(data)
    return path


def _extract_text_list(values: Any) -> List[str]:
    if not isinstance(values, list):
        return []

    output: List[str] = []
    for item in values:
        if isinstance(item, str):
            output.append(item)
            continue
        if isinstance(item, dict):
            name = item.get("description")
            if isinstance(name, str):
                output.append(name)
    return output


def _iso_release_date(data: Dict[str, Any]) -> Optional[str]:
    value = data.get("release_date")
    if not isinstance(value, dict):
        return None

    date_value = value.get("date")
    if not isinstance(date_value, str) or not date_value:
        return None

    try:
        parsed = datetime.strptime(date_value, "%d %b, %Y")
        return parsed.strftime("%Y-%m-%d")
    except ValueError:
        return date_value.strip()


def _make_output(
    *,
    status: str,
    reason: Optional[str],
    error: Optional[str],
    data: Dict[str, Any],
) -> Dict[str, Any]:
    return {
        "status": status,
        "reason": reason,
        "error": error,
        "data": data,
    }


def _build_summary(
    *,
    game: str,
    appid: int,
    selected: Dict[str, Any],
    data: Dict[str, Any],
    covers: Dict[str, str],
    cover_key: str,
    cover_url: str,
    image_path: Optional[Path],
    storesearch_url: str,
    appdetails_url: str,
) -> Dict[str, Any]:
    summary: Dict[str, Any] = {
        "game": game,
        "appid": appid,
        "store_appid": appid,
        "name": data.get("name"),
        "store_url": _STEAM_APP_URL.format(appid=appid),
        "short_description": data.get("short_description"),
        "detailed_description": data.get("detailed_description"),
        "is_free": data.get("is_free"),
        "release_date": _iso_release_date(data),
        "developers": _extract_text_list(data.get("developers")),
        "publishers": _extract_text_list(data.get("publishers")),
        "platforms": data.get("platforms"),
        "genres": _extract_text_list(data.get("genres")),
        "categories": _extract_text_list(data.get("categories")),
        "metacritic": data.get("metacritic"),
        "storesearch_url": storesearch_url,
        "appdetails_url": appdetails_url,
        "cover_key": cover_key,
        "cover_images": covers,
        "available_cover_keys": list(covers.keys()),
        "storesearch_selected": {
            "id": selected.get("id"),
            "name": selected.get("name"),
            "type": selected.get("type"),
            "tiny_image": _normalize_url(selected.get("tiny_image")),
        },
        "image_url_used": cover_url,
    }

    if image_path is not None:
        summary["image_path"] = str(image_path.resolve())

    return {k: v for k, v in summary.items() if v not in (None, [], {}, "")}


def main() -> int:
    args = _parse_args()

    storesearch_url = _build_storesearch_url(args.game, args.lang, args.cc)

    try:
        search_result, reason = _search_game(args.game, args.lang, args.cc, args.select_index)
    except Exception as exc:
        _safe_json_print(
            _make_output(
                status="failed",
                reason="search_failed",
                error=str(exc),
                data={
                    "game": args.game,
                    "storesearch_url": storesearch_url,
                },
            )
        )
        return 1

    if reason == "no_results":
        _safe_json_print(
            _make_output(
                status="not_available",
                reason="no_results",
                error="Steam search has no matched items",
                data={
                    "game": args.game,
                    "storesearch_url": storesearch_url,
                },
            )
        )
        return 2

    selected = search_result.get("selected", {})
    if not isinstance(selected, dict):
        _safe_json_print(
            _make_output(
                status="failed",
                reason="invalid_search_response",
                error="Storesearch response format is invalid",
                data={"game": args.game, "storesearch_url": storesearch_url},
            )
        )
        return 3

    appid = _extract_appid(selected)
    if appid is None:
        _safe_json_print(
            _make_output(
                status="not_available",
                reason="no_appid",
                error="Storesearch item has no appid field",
                data={
                    "game": args.game,
                    "storesearch_selected": selected,
                    "storesearch_url": storesearch_url,
                },
            )
        )
        return 4

    appdetails_url = _build_appdetails_url(appid, args.lang, args.cc)
    try:
        details_result = _fetch_appdetails(appid, args.lang, args.cc)
    except Exception as exc:
        _safe_json_print(
            _make_output(
                status="failed",
                reason="appdetails_failed",
                error=str(exc),
                data={
                    "game": args.game,
                    "appid": appid,
                    "storesearch_url": storesearch_url,
                    "appdetails_url": appdetails_url,
                },
            )
        )
        return 5

    payload = details_result.get("data", {})
    if not isinstance(payload, dict):
        _safe_json_print(
            _make_output(
                status="failed",
                reason="invalid_appdetails_data",
                error="appdetails payload invalid",
                data={
                    "game": args.game,
                    "appid": appid,
                    "storesearch_url": storesearch_url,
                    "appdetails_url": appdetails_url,
                },
            )
        )
        return 6

    covers = _collect_covers(payload)
    cover_key, cover_url = _pick_cover(covers, args.cover_key)
    if not cover_url:
        _safe_json_print(
            _make_output(
                status="not_available",
                reason="no_cover",
                error="appdetails did not return a usable cover URL",
                data=_build_summary(
                    game=args.game,
                    appid=appid,
                    selected=selected,
                    data=payload,
                    covers=covers,
                    cover_key="",
                    cover_url="",
                    image_path=None,
                    storesearch_url=storesearch_url,
                    appdetails_url=appdetails_url,
                ),
            )
        )
        return 7

    out_dir = Path(args.out_dir).expanduser().resolve()
    image_path = _download_image(
        cover_url,
        out_dir,
        _slugify(str(payload.get("name") or str(args.game)), 28),
        appid,
        cover_key,
    )

    _safe_json_print(
        _make_output(
            status="success",
            reason=None,
            error=None,
            data=_build_summary(
                game=args.game,
                appid=appid,
                selected=selected,
                data=payload,
                covers=covers,
                cover_key=cover_key,
                cover_url=cover_url,
                image_path=image_path,
                storesearch_url=storesearch_url,
                appdetails_url=appdetails_url,
            ),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
