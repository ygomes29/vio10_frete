import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { handleOfferRespondPost } from "./offer-respond-handler";
import { createActionLink } from "@/lib/auth/signed-link";
import type { RpcResult } from "@/lib/rpc/result";

const SIGNING_SECRET = "test-signing-secret-very-long-XXXXXXXXXXXXX";

const getUserMock = vi.fn();
const userClientMock = { auth: { getUser: getUserMock } };

vi.mock("@/lib/supabase/server-client", () => ({
  createServerClient: async () => userClientMock,
}));

// system-client só é instanciado se a route usar; o handler não cria system client
// (opts.runSystem é um callback injetado nos testes), então não precisamos mocká-lo real.

function makeCookieRequest(offerId: string, body: unknown): Request {
  return new Request(`http://localhost/api/offers/${offerId}/respond`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

function makeTokenRequest(offerId: string, token: string, body: unknown): Request {
  return new Request(`http://localhost/api/offers/${offerId}/respond?token=${token}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

const validValidate = (b: unknown): string | null => {
  const o = b as { driver_id?: string; response_type?: string } | null;
  if (!o || typeof o !== "object") return "invalid_param";
  if (!o.driver_id) return "invalid_param";
  if (o.response_type !== "accept" && o.response_type !== "counter_bid" && o.response_type !== "decline") {
    return "invalid_response_type";
  }
  return null;
};

const OK: RpcResult = { ok: true, reason: null, delivery_offer_id: "of1" };

beforeEach(() => {
  getUserMock.mockReset();
  process.env.ACTION_LINK_SIGNING_SECRET = SIGNING_SECRET;
});

afterEach(() => {
  delete process.env.ACTION_LINK_SIGNING_SECRET;
  vi.restoreAllMocks();
});

describe("handleOfferRespondPost — dual auth", () => {
  it("cookie JWT válido → runUser (driver_id do body)", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const runUser = vi.fn(async (_c: string, input: { driverId: string }) => OK);
    const runSystem = vi.fn(async () => OK);
    const res = await handleOfferRespondPost(
      makeCookieRequest("of1", { driver_id: "d1", response_type: "accept" }),
      "of1",
      { validate: validValidate, runUser, runSystem },
    );
    expect(res.status).toBe(200);
    expect(runUser).toHaveBeenCalledTimes(1);
    expect(runSystem).not.toHaveBeenCalled();
    const input = runUser.mock.calls[0][1];
    expect(input.driverId).toBe("d1");
  });

  it("sem cookie nem token → 401 unauthenticated", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const req = new Request("http://localhost/api/offers/of1/respond", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ driver_id: "d1", response_type: "accept" }),
    });
    const res = await handleOfferRespondPost(req, "of1", {
      validate: validValidate,
      runUser: vi.fn(),
      runSystem: vi.fn(),
    });
    expect(res.status).toBe(401);
  });

  it("token válido → runSystem (driver_id do token, NÃO do body)", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const link = createActionLink({ offerId: "of1", driverId: "d9" });
    const runUser = vi.fn();
    const runSystem = vi.fn(async (_c: string, input: { driverId: string; offerId: string }) => OK);
    const res = await handleOfferRespondPost(
      makeTokenRequest("of1", link.token, { response_type: "accept" }),
      "of1",
      { validate: validValidate, runUser, runSystem },
    );
    expect(res.status).toBe(200);
    expect(runSystem).toHaveBeenCalledTimes(1);
    expect(runUser).not.toHaveBeenCalled();
    const input = runSystem.mock.calls[0][1];
    expect(input.driverId).toBe("d9"); // do token, não do body
    expect(input.offerId).toBe("of1");
  });

  it("token de outra offer (IDOR) → 401", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const link = createActionLink({ offerId: "of2", driverId: "d9" });
    const res = await handleOfferRespondPost(
      makeTokenRequest("of1", link.token, { response_type: "accept" }),
      "of1",
      { validate: validValidate, runUser: vi.fn(), runSystem: vi.fn() },
    );
    expect(res.status).toBe(401);
  });

  it("token expirado → 401", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const link = createActionLink({ offerId: "of1", driverId: "d9", ttlSeconds: -10 });
    const res = await handleOfferRespondPost(
      makeTokenRequest("of1", link.token, { response_type: "accept" }),
      "of1",
      { validate: validValidate, runUser: vi.fn(), runSystem: vi.fn() },
    );
    expect(res.status).toBe(401);
  });

  it("token tampered (sig alterada) → 401", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const link = createActionLink({ offerId: "of1", driverId: "d9" });
    const tampered = link.token.slice(0, -4) + "AAAA";
    const res = await handleOfferRespondPost(
      makeTokenRequest("of1", tampered, { response_type: "accept" }),
      "of1",
      { validate: validValidate, runUser: vi.fn(), runSystem: vi.fn() },
    );
    expect(res.status).toBe(401);
  });

  it("token via header x-offer-token também funciona", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const link = createActionLink({ offerId: "of1", driverId: "d9" });
    const runSystem = vi.fn(async () => OK);
    const req = new Request("http://localhost/api/offers/of1/respond", {
      method: "POST",
      headers: { "content-type": "application/json", "x-offer-token": link.token },
      body: JSON.stringify({ response_type: "accept" }),
    });
    const res = await handleOfferRespondPost(req, "of1", {
      validate: validValidate,
      runUser: vi.fn(),
      runSystem,
    });
    expect(res.status).toBe(200);
    expect(runSystem).toHaveBeenCalledTimes(1);
  });

  it("cookie válido mas validate falha → 400, NÃO chama run", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const runUser = vi.fn();
    const res = await handleOfferRespondPost(
      makeCookieRequest("of1", { driver_id: "d1", response_type: "bogus" }),
      "of1",
      { validate: validValidate, runUser, runSystem: vi.fn() },
    );
    expect(res.status).toBe(400);
    expect(runUser).not.toHaveBeenCalled();
  });

  it("token válido mas validate falha → 400", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const link = createActionLink({ offerId: "of1", driverId: "d9" });
    const runSystem = vi.fn();
    const res = await handleOfferRespondPost(
      makeTokenRequest("of1", link.token, { response_type: "bogus" }),
      "of1",
      { validate: validValidate, runUser: vi.fn(), runSystem },
    );
    expect(res.status).toBe(400);
    expect(runSystem).not.toHaveBeenCalled();
  });

  it("runUser retorna ok:false offer_already_responded → 409", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const runUser = vi.fn(async () => ({ ok: false, reason: "offer_already_responded" } as RpcResult));
    const res = await handleOfferRespondPost(
      makeCookieRequest("of1", { driver_id: "d1", response_type: "accept" }),
      "of1",
      { validate: validValidate, runUser, runSystem: vi.fn() },
    );
    expect(res.status).toBe(409);
  });

  it("runSystem lança exceção → 500 internal_error", async () => {
    getUserMock.mockResolvedValue({ data: { user: null } });
    const link = createActionLink({ offerId: "of1", driverId: "d9" });
    const runSystem = vi.fn(async () => {
      throw new Error("boom");
    });
    const res = await handleOfferRespondPost(
      makeTokenRequest("of1", link.token, { response_type: "accept" }),
      "of1",
      { validate: validValidate, runUser: vi.fn(), runSystem },
    );
    expect(res.status).toBe(500);
    const j = await res.json();
    expect(j.reason).toBe("internal_error");
  });

  it("body JSON inválido → 400", async () => {
    getUserMock.mockResolvedValue({ data: { user: { id: "u1" } } });
    const req = new Request("http://localhost/api/offers/of1/respond", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{bad",
    });
    const res = await handleOfferRespondPost(req, "of1", {
      validate: validValidate,
      runUser: vi.fn(),
      runSystem: vi.fn(),
    });
    expect(res.status).toBe(400);
  });
});