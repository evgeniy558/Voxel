# Sphere Admin (Next.js)

Локально:

```bash
cd admin
npm install
echo 'NEXT_PUBLIC_SPHERE_API_BASE=https://your-backend.onrender.com' > .env.local
npm run dev
```

Откройте http://localhost:3001/login — войдите **аккаунтом с `is_admin = true`** в Postgres.

SQL (один раз):

```sql
UPDATE users SET is_admin = true WHERE email = 'your@email.com';
```

## Деплой на поддомен `admin.spheremusic.space`

1. В Render создайте **Web Service** из репозитория, root `admin/`, **Build** `npm install && npm run build`, **Start** `npm start` (Next.js слушает порт из `PORT`).
2. В **Environment** задайте `NEXT_PUBLIC_SPHERE_API_BASE=https://<ваш-api>.onrender.com` (без завершающего `/`).
3. В REG.RU (или где у вас DNS для `spheremusic.space`) добавьте **CNAME**: имя `admin` → ваш сервис на Render (hostname из вкладки **Settings → Custom Domain** после привязки домена).

Альтернатива: **Vercel** — импорт каталога `admin`, тот же env.

Статический экспорт (`output: 'export'` в `next.config.mjs`) можно использовать только если убрать SSR-зависимости; текущая сборка рассчитана на обычный Node `npm start`.

Для чистого статического экспорта можно добавить в `next.config.mjs`:

```js
output: 'export',
```

и деплоить содержимое `out/` на любой CDN.
