#!/usr/bin/env python3
"""Fetch NASA Astronomy Picture of the Day metadata and image."""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlsplit, unquote
from urllib.request import Request, urlopen


APOD_API = "https://api.nasa.gov/planetary/apod"
APOD_WEB_BASE = "https://apod.nasa.gov/apod/"
_IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp", ".tif", ".tiff"}


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Fetch NASA APOD image and metadata")
    parser.add_argument(
        "--date",
        help="APOD date in YYYY-MM-DD format. Empty means latest.",
    )
    parser.add_argument(
        "--api-key",
        default="DEMO_KEY",
        help="NASA API key (default: DEMO_KEY)",
    )
    parser.add_argument(
        "--out-dir",
        default=str(Path.cwd() / "work"),
        help="Directory to save downloaded image",
    )
    parser.add_argument(
        "--prefer-hd",
        action="store_true",
        help="Prefer hdurl when available",
    )
    return parser.parse_args()


def _http_get(url: str) -> Tuple[bytes, str]:
    req = Request(
        url,
        headers={
            "Accept": "text/html,application/json;q=0.9,*/*;q=0.8",
            "User-Agent": "avcs-data-prodiver-apod",
        },
    )
    try:
        with urlopen(req, timeout=30) as resp:
            content_type = resp.headers.get("Content-Type", "")
            return resp.read(), content_type
    except HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        raise RuntimeError(f"HTTP {exc.code} while requesting {url}: {body}") from exc
    except URLError as exc:
        raise RuntimeError(f"Network error while requesting {url}: {exc}") from exc


def _build_api_url(date: str | None, api_key: str) -> str:
    params = {"api_key": api_key}
    if date:
        params["date"] = date
    return f"{APOD_API}?{urlencode(params)}"


def _build_web_url(date: str | None) -> str:
    if date:
        dt = datetime.strptime(date, "%Y-%m-%d")
        return f"{APOD_WEB_BASE}ap{dt.strftime('%y%m%d')}.html"
    return f"{APOD_WEB_BASE}astropix.html"


def _sanitize_text(value: str) -> str:
    value = value.replace("\r", " ")
    value = re.sub(r"<[^>]+>", " ", value)
    value = re.sub(r"\s+", " ", value)
    return value.strip()


def _strip_script_and_style(html: str) -> str:
    html = re.sub(r"(?is)<script.*?</script>", " ", html)
    html = re.sub(r"(?is)<style.*?</style>", " ", html)
    return html


def _guess_suffix(url: str) -> str:
    parts = urlsplit(url)
    path = unquote(parts.path)
    suffix = Path(path).suffix.lower()
    if suffix in _IMAGE_EXTENSIONS:
        return suffix
    return ".jpg"


def _slugify(value: str, max_len: int = 24) -> str:
    safe = [
        ch.lower() if ch.isalnum() or ch in "._-" else "-" for ch in value.strip().replace(" ", "-")
    ]
    slug = "".join(safe).strip("-._")
    slug = "-".join([part for part in slug.split("-") if part])
    if not slug:
        slug = "apod-image"
    return slug[:max_len]


def _now_date() -> str:
    return datetime.now().strftime("%Y-%m-%d")


def _fetch_api_payload(url: str) -> Dict[str, Any]:
    payload_bytes, _ = _http_get(url)
    payload = json.loads(payload_bytes.decode("utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError("APOD API returned unexpected payload type")

    if payload.get("error"):
        error = payload.get("error")
        if isinstance(error, dict):
            code = error.get("code")
            msg = error.get("msg") or error.get("message") or ""
            detail = f"{code}: {msg}" if code else msg
        else:
            detail = str(error)
        raise RuntimeError(f"APOD API returned error: {detail}")

    return payload


def _parse_web_date(html: str, fallback: str | None = None) -> str:
    match = re.search(r"\n\s*(\d{4}\s+[A-Za-z]+\s+\d{1,2})\s*<br", html)
    if match:
        raw = match.group(1).strip()
        for fmt in ("%Y %B %d", "%Y %b %d"):
            try:
                return datetime.strptime(raw, fmt).strftime("%Y-%m-%d")
            except ValueError:
                continue

    return fallback or _now_date()


def _extract_web_title(html: str) -> str:
    candidates = [
        r"<center>\s*<b>\s*(.*?)\s*</b>\s*<br>\s*<b>\s*Image Credit:\s*</b>",
        r"<title>\s*(.*?)\s*- Astronomy Picture of the Day\s*</title>",
        r"<title>\s*(.*?)\s*</title>",
    ]

    for pattern in candidates:
        match = re.search(pattern, html, flags=re.I | re.S)
        if match:
            text = _sanitize_text(match.group(1))
            if text:
                return text

    return "APOD"


def _extract_web_explanation(html: str) -> str:
    match = re.search(
        r"<b>\s*Explanation:\s*</b>\s*(.*?)<p>\s*<center>",
        html,
        flags=re.I | re.S,
    )
    if match:
        return _sanitize_text(_strip_script_and_style(match.group(1)))

    plain = _strip_script_and_style(html)
    match = re.search(
        r"</center>\s*<p>\s*(.*?)<p>\s*<center>\s*<b>\s*Tomorrow's picture",
        plain,
        flags=re.I | re.S,
    )
    if match:
        return _sanitize_text(match.group(1))

    return ""


def _extract_web_copyright(html: str) -> Optional[str]:
    match = re.search(r"<b>\s*Copyright:\s*</b>\s*([^<]+)", html, flags=re.I | re.S)
    if match:
        return _sanitize_text(match.group(1)).strip(". )")

    return None


def _extract_web_image_url(html: str, base_url: str) -> Optional[str]:
    compact = _strip_script_and_style(html)

    def candidates(pattern: str):
        for m in re.finditer(pattern, compact, flags=re.I):
            yield m.group(1).strip()

    for raw in candidates(r"<img[^>]*\bsrc\s*=\s*\"([^\"]+)\""):
        if any(token in raw.lower() for token in ("logo", "spacer", "pixel", "nav")):
            continue
        abs_url = urljoin(base_url, raw)
        if Path(urlsplit(abs_url).path).suffix.lower() in _IMAGE_EXTENSIONS:
            return abs_url

    for raw in candidates(r"<img[^>]*\bsrc\s*=\s*'([^']+)'"):
        if any(token in raw.lower() for token in ("logo", "spacer", "pixel", "nav")):
            continue
        abs_url = urljoin(base_url, raw)
        if Path(urlsplit(abs_url).path).suffix.lower() in _IMAGE_EXTENSIONS:
            return abs_url

    return None


def _is_video_only(html: str) -> bool:
    return bool(
        re.search(
            r"<iframe[^>]*src=\"[^\"]*(youtube|vimeo|video)",
            html,
            flags=re.I,
        )
    )


def _fetch_web_payload(date: str | None) -> Tuple[Dict[str, Any], Optional[str]]:
    page_url = _build_web_url(date)
    html_bytes, _ = _http_get(page_url)
    html = html_bytes.decode("utf-8", errors="replace")

    title = _extract_web_title(html)
    explanation = _extract_web_explanation(html)
    image_url = _extract_web_image_url(html, page_url)
    media_type = "image" if image_url else ("video" if _is_video_only(html) else "other")

    payload: Dict[str, Any] = {
        "date": _parse_web_date(html, fallback=date),
        "title": title,
        "explanation": explanation,
        "copyright": _extract_web_copyright(html),
        "media_type": media_type,
        "url": page_url,
    }

    return payload, image_url


def _download_image(url: str, path: Path) -> None:
    data, _ = _http_get(url)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def _make_output(
    *,
    payload: Dict[str, Any],
    status: str,
    source: str,
    api_url: str,
    image_path: Path | None = None,
    image_url_used: str | None = None,
    reason: str | None = None,
    error: str | None = None,
) -> Dict[str, Any]:
    data: Dict[str, Any] = {
        "date": payload.get("date", _now_date()),
        "title": payload.get("title"),
        "explanation": payload.get("explanation"),
        "copyright": payload.get("copyright"),
        "media_type": payload.get("media_type"),
        "source": source,
        "api_url": api_url,
        "url": payload.get("url"),
        "apod_url": payload.get("url"),
    }

    if image_path is not None and image_url_used is not None:
        data["image_path"] = str(image_path.resolve())
        data["image_url_used"] = image_url_used

    return {
        "status": status,
        "reason": reason,
        "error": error,
        "data": data,
    }


def _safe_json_print(payload: Dict[str, Any]) -> None:
    print(json.dumps(payload, ensure_ascii=False), file=sys.stdout, flush=True)


def main() -> int:
    args = _parse_args()

    if args.date:
        try:
            datetime.strptime(args.date, "%Y-%m-%d")
        except ValueError:
            _safe_json_print(
                {
                    "status": "failed",
                    "reason": "invalid_date",
                    "error": "Date must follow YYYY-MM-DD format",
                    "data": None,
                }
            )
            return 2

    api_url = _build_api_url(args.date, args.api_key)
    source = "api"
    payload: Optional[Dict[str, Any]] = None
    image_url: Optional[str] = None
    api_error: str | None = None

    try:
        payload = _fetch_api_payload(api_url)
    except Exception as exc:
        api_error = str(exc)

    if payload is None:
        source = "web_scrape"
        try:
            payload, image_url = _fetch_web_payload(args.date)
        except Exception as exc:
            _safe_json_print(
                {
                    "status": "failed",
                    "reason": "api_and_web_failed",
                    "error": f"API failure: {api_error}; web scrape failure: {exc}",
                    "data": {
                        "api_url": api_url,
                    },
                }
            )
            return 3

        if payload.get("media_type") != "image":
            _safe_json_print(
                _make_output(
                    payload=payload,
                    status="not_available",
                    source=source,
                    api_url=api_url,
                    reason="media_type_is_not_image",
                    error=f"APOD entry is not an image: {payload.get('media_type')}",
                )
            )
            return 4

    if payload is None:
        _safe_json_print(
            {
                "status": "failed",
                "reason": "payload_unavailable",
                "error": api_error or "APOD data unavailable",
                "data": {
                    "api_url": api_url,
                },
            }
        )
        return 3

    if payload.get("media_type") != "image":
        _safe_json_print(
            _make_output(
                payload=payload,
                status="not_available",
                source=source,
                api_url=api_url,
                reason="media_type_is_not_image",
                error=f"APOD entry is not an image: {payload.get('media_type')}",
            )
        )
        return 4

    if image_url is None:
        image_url = payload.get("url")
        hd_url = payload.get("hdurl")
        if args.prefer_hd and isinstance(hd_url, str) and hd_url:
            image_url = hd_url

    if not image_url:
        _safe_json_print(
            _make_output(
                payload=payload,
                status="not_available",
                source=source,
                api_url=api_url,
                reason="missing_image_url",
                error="APOD response has no valid image URL.",
            )
        )
        return 5

    date_value = payload.get("date") or args.date or _now_date()
    slug = _slugify(str(payload.get("title") or "apod"), 20)
    out_dir = Path(args.out_dir).expanduser().resolve()
    filename = f"apod-{date_value}-{slug}{_guess_suffix(image_url)}"
    image_path = out_dir / filename

    try:
        _download_image(image_url, image_path)
    except Exception as exc:
        _safe_json_print(
            _make_output(
                payload=payload,
                status="failed",
                source=source,
                api_url=api_url,
                reason="image_download_failed",
                error=str(exc),
            )
        )
        return 6

    _safe_json_print(
        _make_output(
            payload=payload,
            status="success",
            source=source,
            api_url=api_url,
            image_path=image_path,
            image_url_used=image_url,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
