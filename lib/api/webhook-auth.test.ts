import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { createHmac } from "node:crypto";
import { verifyDatacrazySignature, getDatacrazySignature } from "./webhook-auth";

const SECRET = "dc-webhook-secret-XXXXXXXXXXXXXXXXXXXXXX";
const RAW = JSON.stringify({ intent: "offer_response", driver_id: "d1" });

function sign(secret: string, body: string): string {
  return createHmac("sha256", secret).update(body).digest("hex");
}

beforeEach(() => {
  process.env.DATACRAZY_WEBHOOK_SECRET = SECRET;
});

afterEach(() => {
  delete process.env.DATACRAZY_WEBHOOK_SECRET;
});

describe("verifyDatacrazySignature", () => {
  it("aceita signature válida do raw body", () => {
    expect(verifyDatacrazySignature(RAW, sign(SECRET, RAW))).toBe(true);
  });

  it("rejeita signature de body diferente", () => {
    expect(verifyDatacrazySignature(RAW, sign(SECRET, "other"))).toBe(false);
  });

  it("rejeita secret diferente", () => {
    expect(verifyDatacrazySignature(RAW, sign("wrong-secret", RAW))).toBe(false);
  });

  it("rejeita header ausente (null)", () => {
    expect(verifyDatacrazySignature(RAW, null)).toBe(false);
  });

  it("rejeita comprimento diferente (não lança em timingSafeEqual)", () => {
    expect(verifyDatacrazySignature(RAW, "short")).toBe(false);
  });

  it("fail-closed: sem DATACRAZY_WEBHOOK_SECRET → recusa tudo", () => {
    delete process.env.DATACRAZY_WEBHOOK_SECRET;
    expect(verifyDatacrazySignature(RAW, sign(SECRET, RAW))).toBe(false);
    expect(verifyDatacrazySignature(RAW, null)).toBe(false);
  });
});

describe("getDatacrazySignature", () => {
  it("lê header x-datacrazy-signature", () => {
    const req = new Request("http://localhost", { headers: { "x-datacrazy-signature": "abc" } });
    expect(getDatacrazySignature(req)).toBe("abc");
  });

  it("retorna null se header ausente", () => {
    const req = new Request("http://localhost");
    expect(getDatacrazySignature(req)).toBeNull();
  });
});