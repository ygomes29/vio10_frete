import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { handleBusinessGet } from "./business-handler";
import type { RpcResult } from "@/lib/rpc/result";

/**
 * Mock do `createServerClient` (user-scoped) + `resolveOrgMemberships` (landing).
 * O handler: getUser → resolveOrgMemberships → 403 se sem membership → run.
 * Espelho de admin-handler.test (Sessão 18), mas membership é set-returning (N:1).
 */
const getUserMock = vi.fn();
const clientMock = { auth: { getUser: getUserMock } };
const resolveMembershipsMock = vi.fn();

type BusinessCtxLike = {
  user: { id: string };
  client: unknown;
  memberships: { organization_id: string; role: string }[];
};
type RunFn = (correlationId: string, url: URL, ctx: BusinessCtxLike) => Promise<RpcResult>;

vi.mock("@/lib/supabase/server-client", () => ({
  createServerClient: async () => clientMock,
}));
vi.mock("@/lib/auth/landing", () => ({
  resolveOrgMemberships: (c: unknown, uid: string) => resolveMembershipsMock(c, uid),
}));

beforeEach(() => {
  getUserMock.mockReset();
  resolveMembershipsMock.mockReset();
});
afterEach(() => vi.restoreAllMocks());

const MEM = [{ organization_id: "org-1", role: "business_owner" }];

describe("handleBusinessGet", () => {
  it("sem cookie (user null) → 401 unauthenticated, NÃO chama run nem resolveOrgMemberships", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const run = vi.fn<RunFn>();
    const res = await handleBusinessGet(new Request("http://localhost/api/business/overview"), {
      eventType: "business.overview",
      run,
    });
    expect(res.status).toBe(401);
    expect((await res.json()).reason).toBe("unauthenticated");
    expect(run).not.toHaveBeenCalled();
    expect(resolveMembershipsMock).not.toHaveBeenCalled();
  });

  it("user válido mas sem membership → 403 not_authorized (defense-in-depth), NÃO chama run", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveMembershipsMock.mockResolvedValue([]); // driver autenticado, sem membership
    const run = vi.fn<RunFn>();
    const res = await handleBusinessGet(new Request("http://localhost/api/business/overview"), {
      eventType: "business.overview",
      run,
    });
    expect(res.status).toBe(403);
    expect((await res.json()).reason).toBe("not_authorized");
    expect(run).not.toHaveBeenCalled();
  });

  it("user business (membership) → chama run c/ ctx.memberships, ok→200 espalha payload", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveMembershipsMock.mockResolvedValue(MEM);
    const run = vi.fn<RunFn>(async () => ({ ok: true, reason: null, kpis: { x: 1 } } as RpcResult));
    const res = await handleBusinessGet(new Request("http://localhost/api/business/overview"), {
      eventType: "business.overview",
      run,
    });
    expect(res.status).toBe(200);
    expect(run).toHaveBeenCalledTimes(1);
    const ctx = run.mock.calls[0][2];
    expect(ctx.memberships).toEqual(MEM);
    expect(ctx.user.id).toBe("u1");
    const j = await res.json();
    expect(j.ok).toBe(true);
    expect(j.kpis.x).toBe(1);
  });

  it("repassa url c/ searchParams ao run (filtros da lista)", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveMembershipsMock.mockResolvedValue(MEM);
    const run = vi.fn<RunFn>(async () => ({ ok: true, reason: null } as RpcResult));
    await handleBusinessGet(
      new Request("http://localhost/api/business/deliveries?status=assigned&offset=25"),
      { eventType: "business.deliveries.list", run },
    );
    const url = run.mock.calls[0][1] as URL;
    expect(url.searchParams.get("status")).toBe("assigned");
    expect(url.searchParams.get("offset")).toBe("25");
  });

  it("run retorna ok:false reason → status mapeado (422 not_found)", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveMembershipsMock.mockResolvedValue(MEM);
    const run = vi.fn<RunFn>(async () => ({ ok: false, reason: "not_found" } as RpcResult));
    const res = await handleBusinessGet(new Request("http://localhost/api/business/deliveries/x"), {
      eventType: "business.deliveries.detail",
      run,
    });
    expect(res.status).toBe(422);
  });

  it("run lança exceção → 500 internal_error", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveMembershipsMock.mockResolvedValue(MEM);
    const run = vi.fn<RunFn>(async () => { throw new Error("boom"); });
    const res = await handleBusinessGet(new Request("http://localhost/api/business/overview"), {
      eventType: "business.overview",
      run,
    });
    expect(res.status).toBe(500);
    expect((await res.json()).reason).toBe("internal_error");
  });

  it("run lança erro c/ status+reason explícitos → esse status (501)", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    resolveMembershipsMock.mockResolvedValue(MEM);
    const err = Object.assign(new Error("geo"), { reason: "geo_provider_not_configured", status: 501 });
    const run = vi.fn<RunFn>(async () => { throw err; });
    const res = await handleBusinessGet(new Request("http://localhost/api/business/overview"), {
      eventType: "business.overview",
      run,
    });
    expect(res.status).toBe(501);
  });
});