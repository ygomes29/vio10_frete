import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RpcResult } from "@/lib/rpc/result";

/**
 * Chamada genérica a uma RPC `returns table(ok, reason, ...)`. Os RPCs ViO10 são
 * SECURITY DEFINER e retornam uma tabela de 1 linha com `(ok, reason, ...)`.
 * Erros do PostgREST (ex.: permissão) sobem como exceção → handler mapeia 500
 * (ou 42501 viria como error, não como row).
 */
export async function callRpc(
  client: SupabaseClient,
  name: string,
  params: Record<string, unknown>,
): Promise<RpcResult> {
  const { data, error } = await client.rpc(name, params);
  if (error) {
    // PGRST/Postgres error — não é um (ok=false, reason) da RPC; sobe.
    const err = new Error(`rpc:${name} ${error.code ?? ""} ${error.message}`);
    (err as Error & { pgcode?: string }).pgcode = error.code ?? undefined;
    throw err;
  }
  const rows = data as RpcResult[] | null;
  const row = rows?.[0];
  if (!row) {
    throw new Error(`rpc:${name} retornou sem linhas`);
  }
  return row;
}