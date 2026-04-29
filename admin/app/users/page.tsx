"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { apiFetch, clearToken, getToken } from "@/lib/api";

type UserRow = {
  id: string;
  email: string;
  name: string;
  is_verified: boolean;
  badge_text: string;
  badge_color: string;
  banned: boolean;
  banned_reason: string;
  is_admin: boolean;
};

export default function UsersPage() {
  const [users, setUsers] = useState<UserRow[]>([]);
  const [q, setQ] = useState("");
  const [err, setErr] = useState<string | null>(null);

  async function load() {
    setErr(null);
    if (!getToken()) {
      window.location.href = "/login";
      return;
    }
    const path = q.trim()
      ? `/admin/users?limit=50&q=${encodeURIComponent(q.trim())}`
      : "/admin/users?limit=50";
    const res = await apiFetch(path);
    if (res.status === 401 || res.status === 403) {
      clearToken();
      window.location.href = "/login";
      return;
    }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      setErr((data as { error?: string }).error || "Ошибка загрузки");
      return;
    }
    setUsers((data as { users: UserRow[] }).users || []);
  }

  useEffect(() => {
    load();
  }, []);

  return (
    <div className="min-h-screen p-6">
      <div className="mx-auto max-w-5xl">
        <div className="mb-6 flex flex-wrap items-center gap-4">
          <h1 className="text-xl font-semibold">Пользователи</h1>
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Поиск email / имя"
            className="flex-1 rounded-xl border border-zinc-700 bg-zinc-900 px-4 py-2 text-sm"
          />
          <button
            type="button"
            onClick={load}
            className="rounded-xl bg-violet-600 px-4 py-2 text-sm font-medium text-white"
          >
            Найти
          </button>
          <Link href="/login" className="text-sm text-zinc-400 underline">
            Выход (очистить токен)
          </Link>
        </div>
        {err && <p className="mb-4 text-red-400">{err}</p>}
        <div className="overflow-x-auto rounded-xl border border-zinc-800">
          <table className="w-full text-left text-sm">
            <thead className="border-b border-zinc-800 bg-zinc-900">
              <tr>
                <th className="p-3">Email</th>
                <th className="p-3">Имя</th>
                <th className="p-3">Verified</th>
                <th className="p-3">Бейдж</th>
                <th className="p-3">Бан</th>
              </tr>
            </thead>
            <tbody>
              {users.map((u) => (
                <tr key={u.id} className="border-b border-zinc-900">
                  <td className="p-3 font-mono text-xs">
                    <Link
                      className="text-violet-400 hover:underline"
                      href={`/users/${u.id}`}
                    >
                      {u.email}
                    </Link>
                  </td>
                  <td className="p-3">{u.name}</td>
                  <td className="p-3">{u.is_verified ? "да" : "—"}</td>
                  <td className="p-3">
                    {u.badge_text ? (
                      <span
                        style={{
                          borderColor: u.badge_color || "#888",
                          color: u.badge_color || "#ccc",
                        }}
                        className="rounded-full border px-2 py-0.5 text-xs"
                      >
                        {u.badge_text}
                      </span>
                    ) : (
                      "—"
                    )}
                  </td>
                  <td className="p-3">
                    {u.banned ? (
                      <span className="text-red-400">да</span>
                    ) : (
                      "—"
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
