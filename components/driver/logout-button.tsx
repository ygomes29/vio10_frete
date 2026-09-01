"use client";

import { useTransition } from "react";
import { signOut } from "@/app/auth/login/actions";
import { Button } from "@/components/ui/button";
import { LogOut } from "lucide-react";

/** Logout (ADR-023 Fase 4). Server Action `signOut` → redirect /auth/login. */
export function LogoutButton() {
  const [pending, start] = useTransition();
  return (
    <Button
      variant="ghost"
      size="sm"
      disabled={pending}
      onClick={() => start(() => signOut())}
      aria-label="Sair"
    >
      <LogOut />
      <span className="hidden sm:inline">Sair</span>
    </Button>
  );
}