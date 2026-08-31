import { describe, it, expect, afterEach, beforeEach } from "vitest";
import { createActionLink, verifyActionLink } from "./signed-link";

const SECRET = "test-signing-secret-32-bytes-min!!";

beforeEach(() => {
  process.env.ACTION_LINK_SIGNING_SECRET = SECRET;
});

afterEach(() => {
  delete process.env.ACTION_LINK_SIGNING_SECRET;
});

describe("createActionLink / verifyActionLink", () => {
  it("gera token verificável c/ offer/driver corretos", () => {
    const link = createActionLink({ offerId: "o1", driverId: "d1" });
    const v = verifyActionLink(link.token, "o1");
    expect(v).not.toBeNull();
    expect(v!.offerId).toBe("o1");
    expect(v!.driverId).toBe("d1");
    expect(typeof v!.exp).toBe("number");
  });

  it("respeita expectedOfferId (IDOR): token de o1 rejeitado p/ o2", () => {
    const link = createActionLink({ offerId: "o1", driverId: "d1" });
    expect(verifyActionLink(link.token, "o2")).toBeNull();
    // sem expectedOfferId → ainda válido (não há checagem de path)
    expect(verifyActionLink(link.token)).not.toBeNull();
  });

  it("token expirado → null", () => {
    const link = createActionLink({ offerId: "o1", driverId: "d1", ttlSeconds: -10 });
    expect(verifyActionLink(link.token, "o1")).toBeNull();
  });

  it("assinatura adulterada → null (timing-safe)", () => {
    const link = createActionLink({ offerId: "o1", driverId: "d1" });
    const [payloadB64, sig] = link.token.split(".");
    const tampered = `${payloadB64}.${sig.replace(/.$/, sig.charAt(0) === "A" ? "B" : "A")}`;
    expect(verifyActionLink(tampered, "o1")).toBeNull();
  });

  it("payload adulterado (sem resign) → null", () => {
    const link = createActionLink({ offerId: "o1", driverId: "d1" });
    const [payloadB64, sig] = link.token.split(".");
    // troca o payload mas mantém a sig antiga → HMAC não bate
    const fakePayload = Buffer.from(
      JSON.stringify({ o: "o2", d: "evil", e: Math.floor(Date.now() / 1000) + 999, n: "x" }),
    ).toString("base64url");
    expect(verifyActionLink(`${fakePayload}.${sig}`, "o2")).toBeNull();
  });

  it("token malformado → null", () => {
    expect(verifyActionLink("not-a-token", "o1")).toBeNull();
    expect(verifyActionLink("a.b.c", "o1")).toBeNull();
    expect(verifyActionLink("", "o1")).toBeNull();
  });

  it("fail-closed: sem secret configurado → verify retorna null, create lança", () => {
    delete process.env.ACTION_LINK_SIGNING_SECRET;
    expect(verifyActionLink("whatever", "o1")).toBeNull();
    expect(() => createActionLink({ offerId: "o1", driverId: "d1" })).toThrow();
  });

  it("expiresAt é ISO string no futuro", () => {
    const link = createActionLink({ offerId: "o1", driverId: "d1", ttlSeconds: 60 });
    const d = new Date(link.expiresAt);
    expect(d.getTime()).toBeGreaterThan(Date.now() - 1000);
    expect(d.toISOString()).toBe(link.expiresAt);
  });

  it("dois links p/ mesma offer têm nonces diferentes (anti-replay de geração)", () => {
    const a = createActionLink({ offerId: "o1", driverId: "d1" });
    const b = createActionLink({ offerId: "o1", driverId: "d1" });
    expect(a.token).not.toBe(b.token);
  });
});