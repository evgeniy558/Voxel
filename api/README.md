# API: Spotify трек → MP3 (через spotisaver.net)

Сервис по ссылке на трек Spotify отдаёт **полный MP3** (качество как у spotisaver.net). Реализован как прокси к [spotisaver.net](https://spotisaver.net): сначала запрос метаданных трека, затем запрос на скачивание, ответ стримится клиенту.

- **GET** `get_playlist.php?url=<spotify_url>&lang=en` — получение данных трека (обязателен заголовок `Referer: https://spotisaver.net/`).
- **POST** `download_track.php` — тело JSON с полем `track` (объект из get_playlist) и служебными полями; ответ — бинарный MP3.

Контракт для приложения Sphere не менялся: `GET /api?url=<spotify_track_url>` → ответ: бинарный MP3.

## Требования

- Python 3.10+
- `flask`, `requests`

## Установка

```bash
cd api
python3 -m venv venv
source venv/bin/activate   # Windows: venv\Scripts\activate
pip install -r requirements.txt
```

## Запуск

```bash
python3 app.py
```

Сервер: `http://0.0.0.0:5001`.

## Использование

```
GET http://localhost:5001/api?url=https://open.spotify.com/track/4jx9GqqVMPacAOKHaFlsLb
```

Ответ: бинарный MP3 (полный трек), `Content-Type: audio/mpeg`, имя файла в `Content-Disposition`.

- **Локально / симулятор:** в приложении в настройках можно оставить поле «URL API Spotify» пустым и указать в коде `spotifyToMp3APIBaseURL` (например `http://192.168.1.5:5001/api?url=`), либо ввести этот URL в настройках.
- **Для всех пользователей и на устройстве:** задеплойте API в облако (см. ниже), затем в коде приложения задайте `spotifyToMp3APIBaseURL` на полученный HTTPS-URL и соберите приложение — тогда у всех будет один общий API.

## Деплой (чтобы работало у всех и на устройстве)

1. Зарегистрируйтесь на [Render.com](https://render.com) (есть бесплатный тариф).
2. New → **Web Service**.
3. Подключите репозиторий с проектом. В настройках сервиса укажите **Root Directory:** `api` (чтобы в корне деплоя были `app.py`, `requirements.txt`, `Procfile`).
4. Остальное Render подхватит сам: **Build** — `pip install -r requirements.txt`, **Start** — из `Procfile`: `gunicorn -w 1 -b 0.0.0.0:$PORT --timeout 120 app:app`.
5. Сохраните и дождитесь деплоя. Render выдаст URL, например `https://sphere-spotify-api.onrender.com`.
6. В Xcode в `ContentView.swift` задайте:
   `private let spotifyToMp3APIBaseURL: String = "https://ВАШ-СЕРВИС.onrender.com/api?url="`
7. Соберите приложение и распространяйте — все пользователи будут использовать этот API по HTTPS.

На бесплатном тарифе Render сервис может «засыпать» после неактивности; первый запрос после этого будет медленнее (пробуждение).

## Зависимость от spotisaver.net

- Работа API зависит от доступности и формата ответов spotisaver.net.
- Запросы к spotisaver.net отправляются с заголовком `Referer: https://spotisaver.net/` (без него их API возвращает «Access denied»).
- Никаких ключей Spotify, YouTube, cookies или ffmpeg не требуется.
