import Link from "next/link";

export default function Home() {
  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-6 p-8">
      <h1 className="text-2xl font-semibold text-white">Sphere Admin</h1>
      <Link
        href="/login"
        className="rounded-xl bg-violet-600 px-6 py-3 font-medium text-white hover:bg-violet-500"
      >
        Войти
      </Link>
    </main>
  );
}
