import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import type { SupabaseClient } from "@supabase/supabase-js";
import { resolveLandingPath, resolveOrgMemberships, resolvePlatformRole } from "./landing";

/**
 * Mock do client user-scoped: `auth.getUser` + `rpc` (my_platform_role /
 * my_org_memberships) + `from("drivers")` chain (select/eq/maybeSingle).
 * resolveLandingPath prioridade: plataforma → driver → business → no_role.
 */
function makeClient(opts: {
  user?: { id: string } | null;
  platformRole?: string | null;
  driverRow?: { id: string } | null;
  memberships?: { organization_id: string; role: string }[];
}): SupabaseClient {
  const getUser = vi.fn(async () => ({ data: { user: opts.user ?? null } }));
  const rpc = vi.fn(async (name: string) => {
    if (name === "my_platform_role") return { data: opts.platformRole ?? null };
    if (name === "my_org_memberships")
      return { data: opts.memberships ?? [] };
    return { data: null };
  });
  const driversChain = {
    select: vi.fn(() => driversChain),
    eq: vi.fn(() => driversChain),
    maybeSingle: vi.fn(async () => ({ data: opts.driverRow ?? null })),
  };
  const client = {
    auth: { getUser },
    rpc,
    from: vi.fn((t: string) => (t === "drivers" ? driversChain : driversChain)),
  };
  return client as unknown as SupabaseClient;
}

beforeEach(() => vi.clearAllMocks());
afterEach(() => vi.restoreAllMocks());

describe("resolveOrgMemberships", () => {
  it("retorna array de memberships via rpc my_org_memberships", async () => {
    const c = makeClient({ memberships: [{ organization_id: "o1", role: "business_owner" }] });
    const m = await resolveOrgMemberships(c, "u1");
    expect(m).toEqual([{ organization_id: "o1", role: "business_owner" }]);
    expect(c.rpc).toHaveBeenCalledWith("my_org_memberships");
  });
  it("sem membership → [] (não undefined)", async () => {
    const c = makeClient({});
    const m = await resolveOrgMemberships(c, "u1");
    expect(m).toEqual([]);
  });
});

describe("resolvePlatformRole", () => {
  it("retorna role via rpc my_platform_role", async () => {
    const c = makeClient({ platformRole: "admin" });
    expect(await resolvePlatformRole(c, "u1")).toBe("admin");
  });
  it("sem role → null", async () => {
    const c = makeClient({});
    expect(await resolvePlatformRole(c, "u1")).toBeNull();
  });
});

describe("resolveLandingPath", () => {
  it("sem user → error unauthenticated", async () => {
    const c = makeClient({ user: null });
    expect(await resolveLandingPath(c)).toEqual({ error: "unauthenticated" });
  });

  it("plataforma (admin) → /admin (prioridade sobre driver/business)", async () => {
    const c = makeClient({ user: { id: "u1" }, platformRole: "admin", driverRow: { id: "d1" }, memberships: [{ organization_id: "o1", role: "business_owner" }] });
    expect(await resolveLandingPath(c)).toEqual({ path: "/admin" });
  });

  it("driver (sem plataforma) → /driver", async () => {
    const c = makeClient({ user: { id: "u1" }, driverRow: { id: "d1" }, memberships: [{ organization_id: "o1", role: "business_owner" }] });
    expect(await resolveLandingPath(c)).toEqual({ path: "/driver" });
  });

  it("business (sem plataforma/driver) → /business via rpc my_org_memberships (RESOLVIDO Sessão 19)", async () => {
    const c = makeClient({ user: { id: "u1" }, memberships: [{ organization_id: "o1", role: "business_user" }] });
    expect(await resolveLandingPath(c)).toEqual({ path: "/business" });
    expect(c.rpc).toHaveBeenCalledWith("my_org_memberships");
  });

  it("nenhum papel → error no_role", async () => {
    const c = makeClient({ user: { id: "u1" } });
    expect(await resolveLandingPath(c)).toEqual({ error: "no_role" });
  });

  it("membership via rpc NÃO via select direto em organization_memberships (grant gap)", async () => {
    const c = makeClient({ user: { id: "u1" }, memberships: [{ organization_id: "o1", role: "business_owner" }] });
    await resolveLandingPath(c);
    // Não deve haver from("organization_memberships") — gap 0015/0017.
    const fromCalls = (c.from as unknown as ReturnType<typeof vi.fn>).mock.calls.map(
      (a: unknown[]) => a[0],
    );
    expect(fromCalls).not.toContain("organization_memberships");
    expect(c.rpc).toHaveBeenCalledWith("my_org_memberships");
  });
});