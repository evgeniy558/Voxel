"""
API: Spotify трек → MP3 через spotisaver.net.
Прокси к spotisaver.net: get_playlist (метаданные) → download_track (MP3).
GET /api?url=<spotify_track_url>
Контракт для приложения: ответ — бинарный MP3 (полный трек).
Зависимости: flask, requests.
"""
import os
import urllib.parse

import requests
from flask import Flask, request, Response, jsonify, stream_with_context

app = Flask(__name__)

SPOTISAVER_BASE = "https://spotisaver.net"
SPOTISAVER_REFERER = "https://spotisaver.net/"
DEFAULT_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
    "Referer": SPOTISAVER_REFERER,
}


def is_spotify_track(url: str) -> bool:
    try:
        p = urllib.parse.urlparse(url)
        return "spotify.com" in p.netloc and "/track/" in p.path
    except Exception:
        return False


def get_track_from_spotisaver(spotify_url: str) -> dict | None:
    """Получить объект трека через get_playlist.php (нужен Referer)."""
    get_playlist_url = f"{SPOTISAVER_BASE}/api/get_playlist.php"
    params = {"url": spotify_url, "lang": "en"}
    try:
        r = requests.get(
            get_playlist_url,
            params=params,
            timeout=15,
            headers=DEFAULT_HEADERS,
        )
        r.raise_for_status()
        data = r.json()
    except requests.RequestException as e:
        app.logger.warning("get_playlist request failed: %s", e)
        return None
    except ValueError:
        app.logger.warning("get_playlist non-JSON response (e.g. Access denied)")
        return None

    if "error" in data:
        app.logger.warning("get_playlist API error: %s", data["error"])
        return None
    tracks = data.get("tracks") or []
    if not tracks:
        return None
    return tracks[0]


def download_track_stream(track: dict):
    """Стримить MP3 от download_track.php (POST)."""
    url = f"{SPOTISAVER_BASE}/api/download_track.php"
    payload = {
        "track": track,
        "download_dir": "downloads",
        "filename_tag": "SPOTISAVER",
        "user_ip": "",
        "is_premium": False,
    }
    r = requests.post(
        url,
        json=payload,
        timeout=120,
        headers={**DEFAULT_HEADERS, "Content-Type": "application/json"},
        stream=True,
    )
    r.raise_for_status()
    # Если бэкенд вернул JSON (ошибка), не стримим как MP3
    ct = (r.headers.get("Content-Type") or "").lower()
    if "application/json" in ct:
        err = r.json() if r.content else {}
        raise RuntimeError(err.get("error", "download_track returned JSON error"))
    return r


@app.route("/api", methods=["GET"])
@app.route("/", methods=["GET"])
def convert():
    raw = (request.args.get("url") or "").strip()
    if not raw:
        return jsonify({"error": "Missing url parameter"}), 400
    url = urllib.parse.unquote(raw)
    if not url.startswith("http"):
        url = "https://" + url

    if not is_spotify_track(url):
        return jsonify({
            "error": "Only Spotify track links are supported. Example: https://open.spotify.com/track/..."
        }), 400

    track = get_track_from_spotisaver(url)
    if not track:
        return jsonify({
            "error": "Could not get track info from spotisaver.net (or track not found)."
        }), 502

    try:
        down = download_track_stream(track)
    except requests.RequestException as e:
        return jsonify({"error": f"Download request failed: {e}"}), 502
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 502

    def generate():
        for chunk in down.iter_content(chunk_size=65536):
            if chunk:
                yield chunk

    filename = "track.mp3"
    try:
        artists = track.get("artists") or []
        name = (track.get("name") or "track").replace("/", "-").replace('"', "'").replace("\\", "-")
        if artists and isinstance(artists[0], str):
            filename = f"{', '.join(artists)} - {name}.mp3"
        else:
            filename = f"{name}.mp3"
    except Exception:
        pass

    return Response(
        stream_with_context(generate()),
        mimetype="audio/mpeg",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
        },
    )


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5001))
    app.run(host="0.0.0.0", port=port)
