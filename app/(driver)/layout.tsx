import type { ReactNode } from "react";
import Link from "next/link";
import { PWARegister } from "@/components/pwa-register";
import { LogoutButton } from "@/components/driver/logout-button";

/**
 * Layout do PWA Entregador (route group `(driver)` — ADR-023 Fase 4 / D4).
 * Header simples + registro do service worker. Middleware já exigiu sessão.
 * `safe-area` p/ notch (viewport-fit=cover).
 */
export default function DriverLayout({ children }: { children: ReactNode }) {
  return (
    <div className="min-h-svh bg-muted/30">
      <PWARegister />
      <header
        className="sticky top-0 z-10 border-b bg-background/95 backdrop-blur"
        style={{ paddingTop: "env(safe-area-inset-top)" }}
      >
        <div className="mx-auto flex h-14 max-w-2xl items-center justify-between px-4">
          <Link href="/driver" className="flex items-center gap-2 font-black text-primary">
            <span className="flex h-7 w-7 items-center justify-center rounded-lg bg-primary text-sm text-primary-foreground">
              V
            </span>
            ViO10
          </Link>
          <div className="flex items-center gap-1">
            <Link
              href="/driver/history"
              className="rounded-md px-2 py-1 text-sm text-muted-foreground hover:bg-muted hover:text-foreground"
            >
              Histórico
            </Link>
            <LogoutButton />
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-2xl px-4 pb-24 pt-4">{children}</main>
    </div>
  );
}