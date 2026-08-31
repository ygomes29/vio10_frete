import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { handleUserPost } from "./user-handler";
import type { RpcResult } from "@/lib/rpc/result";

/**
 * Mock do `createServerClient` (user-scoped). O handler chama
 * `await createServerClient()` → `client.auth.getUser()`. Controlamos `user`
 * para exercitar 401 vs. fluxo autenticado.
 */
const getUserMock = vi.fn();
const clientMock = { auth: { getUser: getUserMock } };

vi.mock("@/lib/supabase/server-client", () => ({
  createServerClient: async () => clientMock,
}));

function makeRequest(body: unknown): Request {
  return new Request("http://localhost/api/driver/x", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

const OK: RpcResult = { ok: true, reason: null, id: "r1" };

beforeEach(() => {
  getUserMock.mockReset();
});

afterEach(() => {
  vi.restoreAllMocks();
});

describe("handleUserPost", () => {
  it("sem cookie (user null) → 401 unauthenticated, NÃO chama run", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const run = vi.fn();
    const res = await handleUserPost(makeRequest({}), { eventType: "t", run });
    expect(res.status).toBe(401);
    const j = await res.json();
    expect(j.reason).toBe("unauthenticated");
    expect(run).not.toHaveBeenCalled();
  });

  it("user válido → chama run com correlation_id, body, ctx; mapeia ok→200", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const run = vi.fn(async (_c: string, _b: unknown, ctx: { user: { id: string } }) => OK);
    const res = await handleUserPost(makeRequest({ x: 1 }), { eventType: "t", run });
    expect(res.status).toBe(200);
    expect(run).toHaveBeenCalledTimes(1);
    const ctx = run.mock.calls[0][2];
    expect(ctx.user.id).toBe("u1");
    const j = await res.json();
    expect(j.ok).toBe(true);
    expect(j.id).toBe("r1");
  });

  it("validate falha (reason) → status mapeado, NÃO chama run", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const run = vi.fn();
    const res = await handleUserPost(makeRequest({}), {
      eventType: "t",
      run,
      validate: () => "invalid_param",
    });
    expect(res.status).toBe(400);
    expect(run).not.toHaveBeenCalled();
  });

  it("body JSON inválido → 400 invalid_param", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const req = new Request("http://localhost/api/x", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{not json",
    });
    const res = await handleUserPost(req, { eventType: "t", run: vi.fn() });
    expect(res.status).toBe(400);
    const j = await res.json();
    expect(j.reason).toBe("invalid_param");
  });

  it("run retorna ok:false reason → status mapeado (409 wrong_state)", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const run = vi.fn(async () => ({ ok: false, reason: "wrong_state" } as RpcResult));
    const res = await handleUserPost(makeRequest({}), { eventType: "t", run });
    expect(res.status).toBe(409);
  });

  it("run lança exceção genérica → 500 internal_error", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const run = vi.fn(async () => {
      throw new Error("boom");
    });
    const res = await handleUserPost(makeRequest({}), { eventType: "t", run });
    expect(res.status).toBe(500);
    const j = await res.json();
    expect(j.reason).toBe("internal_error");
  });

  it("run lança erro c/ status+reason explícitos → esse status", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const err = Object.assign(new Error("geo"), { reason: "geo_provider_not_configured", status: 501 });
    const run = vi.fn(async () => {
      throw err;
    });
    const res = await handleUserPost(makeRequest({}), { eventType: "t", run });
    expect(res.status).toBe(501);
    const j = await res.json();
    expect(j.reason).toBe("geo_provider_not_configured");
  });

  it("body vazio (string vazia) → body=null, validate decide", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const req = new Request("http://localhost/api/x", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "",
    });
    const run = vi.fn(async (_c: string, body: unknown) => ({ ok: true, reason: null, got: body } as RpcResult));
    const res = await handleUserPost(req, { eventType: "t", run });
    expect(res.status).toBe(200);
    expect(run.mock.calls[0][1]).toBeNull();
  });
});