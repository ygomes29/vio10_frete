import { describe, it, expect, vi } from "vitest";
import { withIdempotency, InFlightError } from "./ledger";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RpcResult } from "@/lib/rpc/result";

/**
 * Mock do SupabaseClient para o ledger. Apenas o caminho `from("integration_events")`
 * é exercitado. `selectRows` é consumido FIFO a cada `select().maybeSingle()`.
 * `upsertRow` é retornado por `upsert().select().maybeSingle()`.
 */
type Row = { id: string; result: unknown; status: string } | null;

function makeClient(opts: { selectRows?: Row[]; upsertRow?: { id: string } | null }): SupabaseClient {
  const selectQueue = [...(opts.selectRows ?? [])];
  const deletes: { id: string }[] = [];
  const upserts: Record<string, unknown>[] = [];
  const builder = (kind: "select" | "upsert" | "update" | "delete", id?: string) => {
    const b = {
      select: () => builder(kind === "upsert" ? "upsert" : "select", id),
      eq: (col: string, val: unknown) => {
        if (kind === "delete" && col === "id") return builder("delete", val as string);
        return b;
      },
      upsert: (row: Record<string, unknown>) => { upserts.push(row); return builder("upsert", id); },
      update: () => builder("update", id),
      delete: () => builder("delete", id),
      maybeSingle: () => {
        if (kind === "upsert") return Promise.resolve({ data: opts.upsertRow ?? null });
        if (kind === "delete") {
          if (id) deletes.push({ id });
          return Promise.resolve({ data: null, error: null });
        }
        if (kind === "update") return Promise.resolve({ data: null, error: null });
        return Promise.resolve({ data: selectQueue.shift() ?? null });
      },
      // Thenable: releaseClaim/recordResult fazem `.delete()/.update().eq()` sem
      // maybeSingle e `await` o builder diretamente.
      then: (resolve: (v: { data: null; error: null }) => void) => {
        if (kind === "delete" && id) deletes.push({ id });
        return Promise.resolve({ data: null, error: null }).then(resolve);
      },
    };
    return b;
  };
  const client = { from: () => builder("select") } as unknown as SupabaseClient;
  (client as unknown as { __deletes: { id: string }[] }).__deletes = deletes;
  (client as unknown as { __upserts: Record<string, unknown>[] }).__upserts = upserts;
  return client;
}

const OK: RpcResult = { ok: true, reason: null, delivery_request_id: "d1" };

describe("withIdempotency", () => {
  it("skip: sem chave de dedup → executa fn uma vez, sem tocar o ledger", async () => {
    const client = makeClient({});
    const fn = vi.fn(async () => OK);
    const res = await withIdempotency(client, { source: "internal-api" }, fn);
    expect(res).toEqual(OK);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("run: primeira call claima, executa e grava resultado", async () => {
    const client = makeClient({ selectRows: [null], upsertRow: { id: "tok-1" } });
    const fn = vi.fn(async () => OK);
    const res = await withIdempotency(client, { source: "internal-api", idempotencyKey: "k1" }, fn);
    expect(res).toEqual(OK);
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("replay: já processado → retorna resultado cacheado, NÃO re-executa fn", async () => {
    const client = makeClient({
      selectRows: [{ id: "tok-1", result: OK, status: "processed" }],
    });
    const fn = vi.fn(async () => ({ ok: true, reason: null, should_not: "run" } as RpcResult));
    const res = await withIdempotency(client, { source: "internal-api", idempotencyKey: "k1" }, fn);
    expect(res).toEqual(OK);
    expect(fn).not.toHaveBeenCalled();
  });

  it("in_flight: claim pendente → lança InFlightError (409)", async () => {
    const client = makeClient({
      selectRows: [{ id: "tok-1", result: null, status: "pending" }],
    });
    const fn = vi.fn(async () => OK);
    await expect(
      withIdempotency(client, { source: "internal-api", idempotencyKey: "k1" }, fn),
    ).rejects.toBeInstanceOf(InFlightError);
    expect(fn).not.toHaveBeenCalled();
  });

  it("race: upsert conflita (data null) → recheck acha pending → in_flight", async () => {
    const client = makeClient({
      selectRows: [null, { id: "tok-x", result: null, status: "pending" }],
      upsertRow: null, // conflito: outra call inseriu
    });
    const fn = vi.fn(async () => OK);
    await expect(
      withIdempotency(client, { source: "internal-api", idempotencyKey: "k1" }, fn),
    ).rejects.toBeInstanceOf(InFlightError);
    expect(fn).not.toHaveBeenCalled();
  });

  it("externalEventId funciona como chave de dedup (replay)", async () => {
    const client = makeClient({
      selectRows: [{ id: "tok-2", result: OK, status: "processed" }],
    });
    const fn = vi.fn(async () => OK);
    const res = await withIdempotency(client, { source: "datacrazy", externalEventId: "evt-9" }, fn);
    expect(res).toEqual(OK);
    expect(fn).not.toHaveBeenCalled();
  });

  it("idempotencyKey tem precedência sobre externalEventId", async () => {
    // Se idempotencyKey presente, select usa coluna idempotency_key; replay por ela.
    const client = makeClient({
      selectRows: [{ id: "tok-1", result: OK, status: "processed" }],
    });
    const fn = vi.fn(async () => OK);
    await withIdempotency(
      client,
      { source: "internal-api", idempotencyKey: "k1", externalEventId: "e1" },
      fn,
    );
    expect(fn).not.toHaveBeenCalled();
  });

  it("fn lança (transitório) → libera a claim (delete), propaga exceção, NÃO grava resultado", async () => {
    // Bug Sessão 16: provider 501/5xx lança; sem release a row ficava pending e
    // retry com mesma chave → in_flight 409. Agora delete libera p/ retry re-executar.
    const client = makeClient({ selectRows: [null], upsertRow: { id: "tok-1" } });
    const deletes = (client as unknown as { __deletes: { id: string }[] }).__deletes;
    const fn = vi.fn(async () => { throw new Error("whatsapp_provider_not_configured"); });
    await expect(
      withIdempotency(client, { source: "internal-api", idempotencyKey: "k-fail" }, fn),
    ).rejects.toThrow("whatsapp_provider_not_configured");
    expect(fn).toHaveBeenCalledTimes(1);
    // claim liberada
    expect(deletes).toEqual([{ id: "tok-1" }]);
  });

  it("fn lança em skip (sem chave) → propaga, sem delete (não há claim)", async () => {
    const client = makeClient({});
    const deletes = (client as unknown as { __deletes: { id: string }[] }).__deletes;
    const fn = vi.fn(async () => { throw new Error("boom"); });
    await expect(
      withIdempotency(client, { source: "internal-api" }, fn),
    ).rejects.toThrow("boom");
    expect(deletes).toEqual([]);
  });

  it("payload null (sensitive/OTP) → insertRow usa {} (coluna NOT NULL, ADR-019 D4)", async () => {
    // Bug Sessão 16: endpoints `sensitive` passam payload:null; a coluna
    // `integration_events.payload` é NOT NULL (default '{}'). Enviar null faz a
    // insert falhar silenciosamente → fallback skip → sem idempotência. {} respeita.
    const client = makeClient({ selectRows: [null], upsertRow: { id: "tok-1" } });
    const upserts = (client as unknown as { __upserts: Record<string, unknown>[] }).__upserts;
    const fn = vi.fn(async () => OK);
    await withIdempotency(
      client,
      { source: "internal-api", idempotencyKey: "k-sens", payload: null },
      fn,
    );
    expect(upserts).toHaveLength(1);
    expect(upserts[0].payload).toEqual({});
    expect(upserts[0].payload).not.toBeNull();
  });

  it("payload explícito → insertRow usa o payload recebido", async () => {
    const client = makeClient({ selectRows: [null], upsertRow: { id: "tok-1" } });
    const upserts = (client as unknown as { __upserts: Record<string, unknown>[] }).__upserts;
    const body = { delivery_request_id: "d1" };
    await withIdempotency(
      client,
      { source: "internal-api", idempotencyKey: "k-body", payload: body },
      async () => OK,
    );
    expect(upserts[0].payload).toBe(body);
  });
});