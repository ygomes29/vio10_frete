import type { ReactNode } from "react";
import Link from "next/link";
import { LogoutButton } from "@/components/driver/logout-button";

/**
 * Layout do Dashboard admin (route group `(admin)` → URL `/admin/...` — Sessão 18 /
 * ADR-024 D5). Desktop-first (`max-w-7xl`), sem PWA. Middleware já exige sessão em
 * `/admin` (307 → `/auth/login`); a checagem de role acontece no handler/context.
 */
export default function AdminLayout({ children }: { children: ReactNode }) {
  return (
    <div className="min-h-svh bg-muted/30">
      <header className="sticky top-0 z-10 border-b bg-background/95 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-7xl items-center justify-between px-4">
          <Link href="/admin" className="flex items-center gap-2 font-black text-primary">
            <span className="flex h-7 w-7 items-center justify-center rounded-lg bg-primary text-sm text-primary-foreground">
              V
            </span>
            ViO10 <span className="text-xs font-medium text-muted-foreground">Admin</span>
          </Link>
          <div className="flex items-center gap-1">
            <Link
              href="/admin"
              className="rounded-md px-2 py-1 text-sm text-muted-foreground hover:bg-muted hover:text-foreground"
            >
              Visão geral
            </Link>
            <Link
              href="/admin/deliveries"
              className="rounded-md px-2 py-1 text-sm text-muted-foreground hover:bg-muted hover:text-foreground"
            >
              Corridas
            </Link>
            <LogoutButton />
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-7xl px-4 py-6">{children}</main>
    </div>
  );
}