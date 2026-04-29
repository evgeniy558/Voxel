import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Sphere Admin",
  description: "Sphere administration",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="ru">
      <body className="min-h-screen">{children}</body>
    </html>
  );
}
