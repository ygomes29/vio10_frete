import type { ReactNode } from "react";

export const metadata = {
  title: "ViO10",
  description: "Plataforma de logística local e fretes rápidos.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="pt-BR">
      <body>{children}</body>
    </html>
  );
}