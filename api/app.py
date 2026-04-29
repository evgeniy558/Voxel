"""
API: Spotify трек → MP3 через spotisaver.net.
Прокси к spotisaver.net: get_playlist (метаданные) → download_track (MP3).
GET /api?url=<spotify_track_url>
Контракт: ответ — бинарный MP3.
"""
import os
import urllib.parse

import requests
from flask import Flask, request, Response, jsonify

app = Flask(__name__)

SPOTISAVER_BASE = "https://spotisaver.net"
SPOTISAVER_REFERER = "https://spotisaver.net/"
DEFAULT_HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Referer": SPOTISAVER_REFERER,
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "en-US,en;q=0.9",
    "Origin": SPOTISAVER_BASE,
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
    ct = (r.headers.get("Content-Type") or "").lower()
    if "application/json" in ct:
        err = r.json() if r.content else {}
        raise RuntimeError(err.get("error", "download_track returned JSON error"))
    return r


@app.route("/api", methods=["GET"])
@app.route("/", methods=["GET"])
def convert():
    # Чтобы в терминале было видно каждый запрос
    url_param = request.args.get("url") or ""
    print(f"[Sphere API] {request.method} {request.path} url={'да' if url_param.strip() else 'нет'}", flush=True)

    raw = (request.args.get("url") or "").strip()
    if not raw:
        print("[Sphere API] ответ 200 (нет url)", flush=True)
        return (
            "Sphere API: добавь параметр ?url= с ссылкой на трек Spotify.\n"
            "Пример: /api?url=https://open.spotify.com/track/...",
            200,
            {"Content-Type": "text/plain; charset=utf-8"},
        )
    url = urllib.parse.unquote(raw)
    if not url.startswith("http"):
        url = "https://" + url

    if not is_spotify_track(url):
        return jsonify({
            "error": "Only Spotify track links are supported. Example: https://open.spotify.com/track/..."
        }), 400

    track = get_track_from_spotisaver(url)
    if not track:
        print("[Sphere API] ответ 502 (spotisaver не вернул трек)", flush=True)
        return jsonify({
            "error": "Could not get track info from spotisaver.net (or track not found)."
        }), 502

    try:
        down = download_track_stream(track)
    except requests.RequestException as e:
        return jsonify({"error": f"Download request failed: {e}"}), 502
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 502

    body = b"".join(down.iter_content(chunk_size=65536))
    if not body:
        return jsonify({"error": "Empty response from spotisaver"}), 502

    filename = "track.mp3"
    try:
        artists = track.get("artists") or []
        name = (track.get("name") or "track").replace("/", "-").replace('"', "'").replace("\\", "-")
        if artists and isinstance(artists[0], str):
            filename = f"{', '.join(artists)} - {name}.mp3"
        else:
            filename = f"{name}.mp3"
        filename = filename.encode("latin-1", "replace").decode("latin-1")
    except Exception:
        pass

    print("[Sphere API] ответ 200 MP3", len(body), "bytes", flush=True)
    return Response(
        body,
        mimetype="audio/mpeg",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "Content-Length": str(len(body)),
        },
    )


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 5001))
    app.run(host="0.0.0.0", port=port)
