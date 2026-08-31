import type { ReactNode } from "react";

/**
 * Placeholder da página de login (ADR-020 D6, ADR-010 D6).
 * Middleware redireciona usuários sem sessão das route groups `(driver|admin|business)`
 * para cá. A UI real (form de email+senha, integração Supabase Auth, redirecionamento
 * por papel) vem nas Sessões 17-19 (PWA entregador / Painel admin / Portal business).
 * Por ora, apenas confirma que o destino do redirect existe.
 */
export default function LoginPage(): ReactNode {
  return (
    <main style={{ fontFamily: "system-ui, sans-serif", padding: "2rem" }}>
      <h1>ViO10 — Entrar</h1>
      <p>Página de login (placeholder). UI nas Sessões 17-19.</p>
    </main>
  );
}