"use server";

import { redirect } from "next/navigation";
import { createServerClient } from "@/lib/supabase/server-client";
import { resolveLandingPath } from "@/lib/auth/landing";

/**
 * Server Action de login (ADR-023 Fase 2 / D3). Origina-se no próprio frontend
 * (Server Action, não Route Handler — BACKEND §3). `createServerClient` lê o
 * cookie store; em Server Action `cookies()` é gravável, então `signInWithPassword`
 * grava a sessão via `setAll`. Depois resolve o papel (RLS) e redireciona.
 *
 * `redirect()` lança um erro especial que o Next intercepta — NÃO pode estar
 * dentro um try/catch que engula `NEXT_REDIRECT`.
 */
export type SignInState = {
  error?: string;
  email?: string;
};

export async function signIn(prev: SignInState, formData: FormData): Promise<SignInState> {
  const email = String(formData.get("email") ?? "").trim();
  const password = String(formData.get("password") ?? "");
  if (!email || !password) return { error: "Informe email e senha.", email };

  const client = await createServerClient();
  const { error } = await client.auth.signInWithPassword({ email, password });
  if (error) {
    return { error: "Email ou senha inválidos.", email };
  }

  // Resolve papel e redireciona. RLS garante leitura das próprias rows.
  const landing = await resolveLandingPath(client);
  if ("error" in landing) {
    // Logado no Auth mas sem papel no sistema — desloga para não deixar sessão órfã.
    await client.auth.signOut();
    return { error: "Usuário sem acesso ao sistema. Contate o administrador.", email };
  }
  redirect(landing.path);
}

export async function signOut(): Promise<void> {
  const client = await createServerClient();
  await client.auth.signOut();
  redirect("/auth/login");
}