import "server-only";
import { createServerClient } from "@/lib/supabase/server-client";
import { resolveDriverId } from "@/lib/services/driver";
import type { SupabaseClient } from "@supabase/supabase-js";

/**
 * Contexto driver server-side (ADR-023 Fase 4). Usado por Server Components sob
 * `(driver)`. Middleware já exige sessão em /driver (307 login); aqui confirmamos
 * sessão + que o user é driver (row em `drivers`). Retorna `{client, driverId}`
 * ou `null` (não auth / não driver) — a página decide (redirect ou mensagem).
 */
export type DriverContext = { client: SupabaseClient; driverId: string };

export async function getDriverContext(): Promise<DriverContext | null> {
  const client = await createServerClient();
  const { data: { user } } = await client.auth.getUser();
  if (!user) return null;
  const driverId = await resolveDriverId(client, user.id);
  if (!driverId) return null;
  return { client, driverId };
}