const API_BASE =
  process.env.NEXT_PUBLIC_SPHERE_API_BASE?.replace(/\/$/, "") ||
  "https://sphere-backend-8ssb.onrender.com";

export function getToken(): string | null {
  if (typeof window === "undefined") return null;
  return localStorage.getItem("sphere_admin_jwt");
}

export function setToken(t: string) {
  localStorage.setItem("sphere_admin_jwt", t);
}

export function clearToken() {
  localStorage.removeItem("sphere_admin_jwt");
}

export async function apiFetch(
  path: string,
  init: RequestInit = {}
): Promise<Response> {
  const token = getToken();
  const headers = new Headers(init.headers);
  headers.set("Accept", "application/json");
  if (token) headers.set("Authorization", `Bearer ${token}`);
  return fetch(`${API_BASE}${path}`, { ...init, headers });
}
