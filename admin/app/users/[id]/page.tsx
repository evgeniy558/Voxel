"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { apiFetch, clearToken, getToken } from "@/lib/api";

type UserDetail = {
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

export default function UserDetailPage() {
  const params = useParams();
  const router = useRouter();
  const id = params.id as string;
  const [user, setUser] = useState<UserDetail | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [badgeText, setBadgeText] = useState("");
  const [badgeColor, setBadgeColor] = useState("#888888");
  const [banReason, setBanReason] = useState("");

  async function load() {
    setErr(null);
    if (!getToken()) {
      router.replace("/login");
      return;
    }
    const res = await apiFetch(`/admin/users/${id}`);
    if (res.status === 401 || res.status === 403) {
      clearToken();
      router.replace("/login");
      return;
    }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      setErr((data as { error?: string }).error || "Error");
      return;
    }
    const u = data as UserDetail;
    setUser(u);
    setBadgeText(u.badge_text || "");
    setBadgeColor(u.badge_color || "#888888");
  }

  useEffect(() => {
    load();
  }, [id]);

  async function saveBadge() {
    const res = await apiFetch(`/admin/users/${id}/badge`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text: badgeText.slice(0, 5), color: badgeColor }),
    });
    if (!res.ok) {
      setErr("Badge save failed");
      return;
    }
    await load();
  }

  async function setVerified(v: boolean) {
    const res = await apiFetch(`/admin/users/${id}/verified`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ value: v }),
    });
    if (!res.ok) setErr("Update failed");
    else await load();
  }

  async function ban() {
    const res = await apiFetch(`/admin/users/${id}/ban`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ reason: banReason }),
    });
    if (!res.ok) setErr("Ban failed");
    else await load();
  }

  async function unban() {
    const res = await apiFetch(`/admin/users/${id}/unban`, { method: "POST" });
    if (!res.ok) setErr("Unban failed");
    else await load();
  }

  if (!user && !err) {
    return (
      <div className="flex min-h-screen items-center justify-center text-zinc-400">
        Loading…
      </div>
    );
  }

  if (!user) {
    return (
      <div className="p-6">
        <p className="text-red-400">{err}</p>
        <Link href="/users" className="text-violet-400 underline">
          Back
        </Link>
      </div>
    );
  }

  return (
    <div className="min-h-screen p-6">
      <div className="mx-auto max-w-lg space-y-6">
        <div className="flex items-center gap-4">
          <Link href="/users" className="text-sm text-violet-400 underline">
            ← Users
          </Link>
        </div>
        <h1 className="text-xl font-semibold">{user.email}</h1>
        <p className="text-sm text-zinc-400">{user.name}</p>
        {err && <p className="text-sm text-red-400">{err}</p>}

        <div className="flex flex-wrap gap-3">
          <button
            type="button"
            onClick={() => setVerified(!user.is_verified)}
            className="rounded-lg border border-zinc-700 px-4 py-2 text-sm"
          >
            {user.is_verified ? "Remove verified" : "Set verified"}
          </button>
          {user.banned ? (
            <button
              type="button"
              onClick={unban}
              className="rounded-lg bg-emerald-700 px-4 py-2 text-sm text-white"
            >
              Unban
            </button>
          ) : (
            <>
              <input
                value={banReason}
                onChange={(e) => setBanReason(e.target.value)}
                placeholder="Ban reason"
                className="flex-1 rounded-lg border border-zinc-700 bg-zinc-900 px-3 py-2 text-sm"
              />
              <button
                type="button"
                onClick={ban}
                className="rounded-lg bg-red-700 px-4 py-2 text-sm text-white"
              >
                Ban
              </button>
            </>
          )}
        </div>

        <div className="space-y-2 rounded-xl border border-zinc-800 p-4">
          <div className="text-sm font-medium">Badge (≤5 chars)</div>
          <div className="flex flex-wrap items-center gap-2">
            <input
              maxLength={5}
              value={badgeText}
              onChange={(e) => setBadgeText(e.target.value)}
              className="w-24 rounded border border-zinc-700 bg-zinc-900 px-2 py-1 text-sm"
            />
            <input
              type="color"
              value={badgeColor}
              onChange={(e) => setBadgeColor(e.target.value)}
              className="h-9 w-14 cursor-pointer rounded border border-zinc-700 bg-transparent"
            />
            <span
              style={{
                borderColor: badgeColor,
                color: badgeColor,
              }}
              className="rounded-full border px-2 py-0.5 text-xs"
            >
              {badgeText || "—"}
            </span>
            <button
              type="button"
              onClick={saveBadge}
              className="rounded-lg bg-violet-600 px-3 py-1 text-sm text-white"
            >
              Save badge
            </button>
          </div>
        </div>

        <div className="text-xs text-zinc-500">
          Admin: {user.is_admin ? "yes" : "no"} · Banned:{" "}
          {user.banned ? user.banned_reason || "yes" : "no"}
        </div>
      </div>
    </div>
  );
}
