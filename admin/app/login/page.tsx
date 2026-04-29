"use client";

import { useRouter } from "next/navigation";
import { FormEvent, useState } from "react";
import { apiFetch, setToken } from "@/lib/api";

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [twoFAChallenge, setTwoFAChallenge] = useState<string | null>(null);
  const [methods, setMethods] = useState<string[]>([]);
  const [twoFACode, setTwoFACode] = useState("");
  const [twoFAMethod, setTwoFAMethod] = useState("email");
  const [err, setErr] = useState<string | null>(null);

  async function doLogin(e: FormEvent) {
    e.preventDefault();
    setErr(null);
    const res = await apiFetch("/auth/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ email, password }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      setErr((data as { error?: string }).error || "Ошибка входа");
      return;
    }
    if ((data as { requires_2fa?: boolean }).requires_2fa) {
      setTwoFAChallenge((data as { challenge_id: string }).challenge_id);
      setMethods((data as { methods?: string[] }).methods || []);
      return;
    }
    const tok = (data as { token?: string }).token;
    if (tok) {
      setToken(tok);
      router.push("/users");
    }
  }

  async function do2FA(e: FormEvent) {
    e.preventDefault();
    setErr(null);
    if (!twoFAChallenge) return;
    const res = await apiFetch("/auth/2fa/verify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        challenge_id: twoFAChallenge,
        method: twoFAMethod,
        code: twoFACode.trim(),
      }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      setErr((data as { error?: string }).error || "Неверный код");
      return;
    }
    const tok = (data as { token?: string }).token;
    if (tok) {
      setToken(tok);
      router.push("/users");
    }
  }

  return (
    <div className="flex min-h-screen items-center justify-center p-6">
      <div className="w-full max-w-md rounded-2xl border border-zinc-800 bg-zinc-900/80 p-8 shadow-xl">
        <h1 className="mb-6 text-center text-xl font-semibold text-white">
          Sphere Admin
        </h1>
        {!twoFAChallenge ? (
          <form onSubmit={doLogin} className="space-y-4">
            <input
              type="email"
              required
              placeholder="Email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white placeholder:text-zinc-500"
            />
            <input
              type="password"
              required
              placeholder="Пароль"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white placeholder:text-zinc-500"
            />
            {err && <p className="text-sm text-red-400">{err}</p>}
            <button
              type="submit"
              className="w-full rounded-xl bg-violet-600 py-3 font-medium text-white hover:bg-violet-500"
            >
              Войти
            </button>
          </form>
        ) : (
          <form onSubmit={do2FA} className="space-y-4">
            <p className="text-sm text-zinc-400">
              Введите код второго фактора ({methods.join(", ")}).
            </p>
            {methods.includes("totp") && methods.includes("email") && (
              <select
                value={twoFAMethod}
                onChange={(e) => setTwoFAMethod(e.target.value)}
                className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white"
              >
                <option value="email">Email</option>
                <option value="totp">Authenticator</option>
              </select>
            )}
            {methods.length === 1 && methods[0] === "totp" && (
              <input type="hidden" value="totp" readOnly />
            )}
            <input
              type="text"
              required
              placeholder="Код"
              value={twoFACode}
              onChange={(e) => setTwoFACode(e.target.value)}
              className="w-full rounded-xl border border-zinc-700 bg-zinc-950 px-4 py-3 text-white"
            />
            {err && <p className="text-sm text-red-400">{err}</p>}
            <button
              type="submit"
              className="w-full rounded-xl bg-violet-600 py-3 font-medium text-white hover:bg-violet-500"
            >
              Подтвердить
            </button>
          </form>
        )}
      </div>
    </div>
  );
}
