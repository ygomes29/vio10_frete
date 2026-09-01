import type { ReactNode } from "react";
import Link from "next/link";
import { LogoutButton } from "@/components/driver/logout-button";

/**
 * Layout do Portal business (route group `(business)` → URL `/business/...` — Sessão
 * 19 / ADR-025 D5). Desktop-first (`max-w-7xl`), sem PWA. Middleware já exige sessão em
 * `/business` (307 → `/auth/login`); a checagem de membership acontece no
 * handler/context. Paleta branco+laranja `#fe7845` (consistente com admin/driver).
 */
export default function BusinessLayout({ children }: { children: ReactNode }) {
  return (
    <div className="min-h-svh bg-muted/30">
      <header className="sticky top-0 z-10 border-b bg-background/95 backdrop-blur">
        <div className="mx-auto flex h-14 max-w-7xl items-center justify-between px-4">
          <Link href="/business" className="flex items-center gap-2 font-black text-primary">
            <span className="flex h-7 w-7 items-center justify-center rounded-lg bg-primary text-sm text-primary-foreground">
              V
            </span>
            ViO10 <span className="text-xs font-medium text-muted-foreground">Empresa</span>
          </Link>
          <div className="flex items-center gap-1">
            <Link
              href="/business"
              className="rounded-md px-2 py-1 text-sm text-muted-foreground hover:bg-muted hover:text-foreground"
            >
              Visão geral
            </Link>
            <Link
              href="/business/deliveries"
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