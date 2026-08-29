import { describe, it, expect, afterEach, beforeEach } from "vitest";
import { verifyInternalApiKey } from "./internal-auth";

const SECRET = "a".repeat(64); // 64 chars hex-like

afterEach(() => {
  delete process.env.INTERNAL_API_KEY;
});

describe("verifyInternalApiKey", () => {
  beforeEach(() => {
    process.env.INTERNAL_API_KEY = SECRET;
  });

  it("aceita secret correto", () => {
    expect(verifyInternalApiKey(SECRET)).toBe(true);
  });

  it("rejeita secret errado", () => {
    expect(verifyInternalApiKey("b".repeat(64))).toBe(false);
  });

  it("rejeita header ausente", () => {
    expect(verifyInternalApiKey(null)).toBe(false);
  });

  it("rejeita comprimento diferente (não lança em timingSafeEqual)", () => {
    expect(verifyInternalApiKey("short")).toBe(false);
  });

  it("fail-closed: sem INTERNAL_API_KEY configurado → recusa tudo", () => {
    delete process.env.INTERNAL_API_KEY;
    expect(verifyInternalApiKey(SECRET)).toBe(false);
    expect(verifyInternalApiKey(null)).toBe(false);
    expect(verifyInternalApiKey("anything")).toBe(false);
  });
});