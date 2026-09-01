import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { handleAdminGet } from "./admin-handler";
import type { RpcResult } from "@/lib/rpc/result";

/**
 * Mock do `createServerClient` (user-scoped) + `resolvePlatformRole` (landing).
 * O handler: getUser → resolvePlatformRole → 403 se não admin → run.
 */
const getUserMock = vi.fn();
const clientMock = { auth: { getUser: getUserMock } };
const resolveRoleMock = vi.fn();

type AdminCtxLike = { user: { id: string }; client: unknown; role: string };
type RunFn = (correlationId: string, url: URL, ctx: AdminCtxLike) => Promise<RpcResult>;

vi.mock("@/lib/supabase/server-client", () => ({
  createServerClient: async () => clientMock,
}));
vi.mock("@/lib/auth/landing", () => ({
  resolvePlatformRole: (c: unknown, uid: string) => resolveRoleMock(c, uid),
}));

beforeEach(() => {
  getUserMock.mockReset();
  resolveRoleMock.mockReset();
});
afterEach(() => vi.restoreAllMocks());

describe("handleAdminGet", () => {
  it("sem cookie (user null) → 401 unauthenticated, NÃO chama run nem resolveRole", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const run = vi.fn<RunFn>();
    const res = await handleAdminGet(new Request("http://localhost/api/admin/overview"), {
      eventType: "admin.overview",
      run,
    });
    expect(res.status).toBe(401);
    expect((await res.json()).reason).toBe("unauthenticated");
    expect(run).not.toHaveBeenCalled();
    expect(resolveRoleMock).not.toHaveBeenCalled();
  });

  it("user válido mas sem role de plataforma → 403 not_authorized (defense-in-depth), NÃO chama run", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveRoleMock.mockResolvedValue(null); // driver autenticado, não-admin
    const run = vi.fn<RunFn>();
    const res = await handleAdminGet(new Request("http://localhost/api/admin/overview"), {
      eventType: "admin.overview",
      run,
    });
    expect(res.status).toBe(403);
    expect((await res.json()).reason).toBe("not_authorized");
    expect(run).not.toHaveBeenCalled();
  });

  it("user admin (role operator) → chama run c/ ctx.role, ok→200 espalha payload", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveRoleMock.mockResolvedValue("operator");
    const run = vi.fn<RunFn>(async () => ({ ok: true, reason: null, kpis: { x: 1 } } as RpcResult));
    const res = await handleAdminGet(new Request("http://localhost/api/admin/overview"), {
      eventType: "admin.overview",
      run,
    });
    expect(res.status).toBe(200);
    expect(run).toHaveBeenCalledTimes(1);
    const ctx = run.mock.calls[0][2];
    expect(ctx.role).toBe("operator");
    expect(ctx.user.id).toBe("u1");
    const j = await res.json();
    expect(j.ok).toBe(true);
    expect(j.kpis.x).toBe(1);
  });

  it("repassa url c/ searchParams ao run (filtros da lista)", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveRoleMock.mockResolvedValue("admin");
    const run = vi.fn<RunFn>(async () => ({ ok: true, reason: null } as RpcResult));
    await handleAdminGet(new Request("http://localhost/api/admin/deliveries?status=assigned&offset=25"), {
      eventType: "admin.deliveries.list",
      run,
    });
    const url = run.mock.calls[0][1] as URL;
    expect(url.searchParams.get("status")).toBe("assigned");
    expect(url.searchParams.get("offset")).toBe("25");
  });

  it("run retorna ok:false reason → status mapeado (422 not_found)", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveRoleMock.mockResolvedValue("admin");
    const run = vi.fn<RunFn>(async () => ({ ok: false, reason: "not_found" } as RpcResult));
    const res = await handleAdminGet(new Request("http://localhost/api/admin/deliveries/x"), {
      eventType: "admin.deliveries.detail",
      run,
    });
    expect(res.status).toBe(422);
  });

  it("run lança exceção → 500 internal_error", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveRoleMock.mockResolvedValue("admin");
    const run = vi.fn<RunFn>(async () => { throw new Error("boom"); });
    const res = await handleAdminGet(new Request("http://localhost/api/admin/overview"), {
      eventType: "admin.overview",
      run,
    });
    expect(res.status).toBe(500);
    expect((await res.json()).reason).toBe("internal_error");
  });

  it("run lança erro c/ status+reason explícitos → esse status (501)", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveRoleMock.mockResolvedValue("admin");
    const err = Object.assign(new Error("geo"), { reason: "geo_provider_not_configured", status: 501 });
    const run = vi.fn<RunFn>(async () => { throw err; });
    const res = await handleAdminGet(new Request("http://localhost/api/admin/overview"), {
      eventType: "admin.overview",
      run,
    });
    expect(res.status).toBe(501);
  });
});