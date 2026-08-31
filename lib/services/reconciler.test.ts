import { describe, it, expect } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import { scanReconciler, validateScanBody } from "./reconciler";

// Mock client: cadeia .select().eq().lt()/.in() awaitable → {data: [...]}.
type Op = { type: "eq" | "lt" | "in"; col: string; val: unknown };
function makeClient(config: Record<string, (ops: Op[]) => unknown[] | null>) {
  const client = {
    from: (table: string) => {
      const ops: Op[] = [];
      const chain = {
        select: () => chain,
        eq: (col: string, val: unknown) => { ops.push({ type: "eq", col, val }); return chain; },
        lt: (col: string, val: unknown) => { ops.push({ type: "lt", col, val }); return chain; },
        in: (col: string, arr: unknown) => { ops.push({ type: "in", col, val: arr }); return chain; },
        then: (resolve: (v: { data: unknown[] | null; error: null }) => void) =>
          resolve({ data: config[table]?.(ops) ?? null, error: null }),
      };
      return chain;
    },
  } as unknown as SupabaseClient;
  return client;
}

describe("validateScanBody", () => {
  it("aceita vazio", () => { expect(validateScanBody(null)).toEqual({ valid: true }); });
  it("aceita stale_after_seconds positivo", () => {
    expect(validateScanBody({ stale_after_seconds: 120 })).toEqual({ valid: true });
  });
  it("rejeita stale_after_seconds <= 0", () => {
    expect(validateScanBody({ stale_after_seconds: 0 })).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita não-objeto", () => {
    expect(validateScanBody("x")).toEqual({ valid: false, reason: "invalid_param" });
  });
});

describe("scanReconciler", () => {
  it("retorna stale_rounds, stale_drafts e orphaned_searching", async () => {
    const client = makeClient({
      dispatch_rounds: (ops) => {
        // chamada 1: eq status=open + lt expires_at (stale rounds)
        if (ops.some((o) => o.type === "lt")) {
          return [{ id: "r1", delivery_request_id: "del1", round_number: 1, expires_at: "2026-01-01T00:00:00Z" }];
        }
        // chamada 2: eq status=open + in delivery_request_id (open rounds p/ orphan check)
        return [{ delivery_request_id: "del-searching-with-open" }];
      },
      delivery_requests: (ops) => {
        const statusOp = ops.find((o) => o.col === "status");
        if (statusOp?.val === "draft") {
          return [{ id: "draft1", created_at: "2026-01-01T00:00:00Z" }];
        }
        if (statusOp?.val === "searching_driver") {
          return [
            { id: "del-searching-with-open", dispatch_started_at: "2026-01-01T00:00:00Z" },
            { id: "del-orphan", dispatch_started_at: null },
          ];
        }
        return [];
      },
    });

    const r = await scanReconciler(client, { stale_after_seconds: 60 });
    expect(r.ok).toBe(true);
    expect(r.stale_rounds).toHaveLength(1);
    expect(r.stale_rounds[0].id).toBe("r1");
    expect(r.stale_drafts).toHaveLength(1);
    expect(r.stale_drafts[0].id).toBe("draft1");
    // del-searching-with-open tem rodada aberta → NÃO é orphan; del-orphan é orphan.
    expect(r.orphaned_searching).toHaveLength(1);
    expect(r.orphaned_searching[0].id).toBe("del-orphan");
  });

  it("sem achados → listas vazias", async () => {
    const client = makeClient({
      dispatch_rounds: () => [],
      delivery_requests: () => [],
    });
    const r = await scanReconciler(client, {});
    expect(r.ok).toBe(true);
    expect(r.stale_rounds).toEqual([]);
    expect(r.stale_drafts).toEqual([]);
    expect(r.orphaned_searching).toEqual([]);
  });
});