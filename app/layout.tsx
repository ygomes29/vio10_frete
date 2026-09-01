import type { ReactNode } from "react";
import type { Viewport } from "next";
import "./globals.css";

export const metadata = {
  title: "ViO10",
  description: "Plataforma de logística local e fretes rápidos.",
  applicationName: "ViO10",
  appleWebApp: {
    capable: true,
    statusBarStyle: "default",
    title: "ViO10 Entregador",
  },
  formatDetection: { telephone: false },
};

export const viewport: Viewport = {
  themeColor: "#3b6df6",
  width: "device-width",
  initialScale: 1,
  maximumScale: 1,
  userScalable: false,
  viewportFit: "cover",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="pt-BR">
      <body className="min-h-screen bg-background text-foreground antialiased">
        {children}
      </body>
    </html>
  );
}