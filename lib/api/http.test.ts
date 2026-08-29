import { describe, it, expect } from "vitest";
import { getCorrelationId, getIdempotencyHeaders } from "./http";

describe("getCorrelationId", () => {
  it("usa o header x-correlation-id quando presente", () => {
    const req = new Request("https://x.test/api", { headers: { "x-correlation-id": "corr-123" } });
    expect(getCorrelationId(req)).toBe("corr-123");
  });

  it("gera um UUID v4 quando ausente", () => {
    const req = new Request("https://x.test/api");
    const id = getCorrelationId(req);
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
  });
});

describe("getIdempotencyHeaders", () => {
  it("lê Idempotency-Key e x-external-event-id", () => {
    const req = new Request("https://x.test/api", {
      headers: { "idempotency-key": "k1", "x-external-event-id": "e1" },
    });
    expect(getIdempotencyHeaders(req)).toEqual({ idempotencyKey: "k1", externalEventId: "e1" });
  });

  it("retorna null quando ausentes", () => {
    const req = new Request("https://x.test/api");
    const h = getIdempotencyHeaders(req);
    expect(h.idempotencyKey).toBeNull();
    expect(h.externalEventId).toBeNull();
  });
});