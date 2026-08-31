import { describe, it, expect } from "vitest";
import { reasonToStatus, isReplay, toApiResponse, redactFields, type RpcResult } from "./result";

describe("reasonToStatus", () => {
  it("mapeia autorização → 403", () => {
    expect(reasonToStatus("not_authorized")).toBe(403);
  });
  it("mapeia input → 400", () => {
    expect(reasonToStatus("invalid_param")).toBe(400);
    expect(reasonToStatus("invalid_bid_amount")).toBe(400);
    expect(reasonToStatus("invalid_response_type")).toBe(400);
    expect(reasonToStatus("invalid_pod")).toBe(400);
  });
  it("mapeia sem/inválido JWT (camada de API) → 401", () => {
    expect(reasonToStatus("unauthenticated")).toBe(401);
  });
  it("mapeia conflitos de estado → 409", () => {
    for (const r of [
      "wrong_state", "round_already_open", "round_not_open", "already_responded",
      "offer_already_responded", "delivery_not_searching", "pod_already_submitted",
      "invalid_transition", "reassignment_limit_reached", "otp_already_used",
    ]) {
      expect(reasonToStatus(r)).toBe(409);
    }
  });
  it("mapeia oferta vencida → 410 (gone)", () => {
    expect(reasonToStatus("offer_expired")).toBe(410);
  });
  it("mapeia offer não pertence ao driver → 404", () => {
    expect(reasonToStatus("offer_not_found_for_driver")).toBe(404);
  });
  it("mapeia pré-condições → 422", () => {
    for (const r of ["not_found", "delivery_not_found", "no_pricing_rule", "pod_required", "pickup_pod_required", "pod_geolocation_out_of_range", "otp_invalid", "otp_expired", "otp_not_generated", "otp_max_attempts"]) {
      expect(reasonToStatus(r)).toBe(422);
    }
  });
  it("reason nulo → 500", () => {
    expect(reasonToStatus(null)).toBe(500);
  });
  it("reason desconhecido → 422 (backend respondeu, não erro de transporte)", () => {
    expect(reasonToStatus("some_new_reason")).toBe(422);
  });
});

describe("isReplay", () => {
  it("true só para idempotent_replay", () => {
    expect(isReplay("idempotent_replay")).toBe(true);
    expect(isReplay("wrong_state")).toBe(false);
    expect(isReplay(null)).toBe(false);
  });
});

describe("toApiResponse", () => {
  it("ok=true → 200 com corpo ok:true + campos do resultado", () => {
    const r: RpcResult = { ok: true, reason: null, delivery_request_id: "d1" };
    const api = toApiResponse(r, { correlation_id: "c1" });
    expect(api.status).toBe(200);
    expect(api.body).toMatchObject({ ok: true, delivery_request_id: "d1", correlation_id: "c1" });
  });

  it("replay → 200 (não 409)", () => {
    const r: RpcResult = { ok: false, reason: "idempotent_replay" };
    expect(toApiResponse(r).status).toBe(200);
  });

  it("ok=false com reason → 4xx + reason no corpo", () => {
    const r: RpcResult = { ok: false, reason: "wrong_state" };
    const api = toApiResponse(r, { correlation_id: "c2" });
    expect(api.status).toBe(409);
    expect(api.body).toMatchObject({ ok: false, reason: "wrong_state", correlation_id: "c2" });
  });
});

describe("redactFields", () => {
  it("remove a chave indicada (otp_code nunca sai do backend — ADR-021 D7)", () => {
    const body = { ok: true, reason: null, otp_code: "123456", delivery_request_id: "d1" };
    const out = redactFields(body, ["otp_code"]);
    expect(out).not.toHaveProperty("otp_code");
    expect(out).toMatchObject({ ok: true, delivery_request_id: "d1" });
  });
  it("não muta o body original", () => {
    const body = { ok: true, otp_code: "123456" };
    redactFields(body, ["otp_code"]);
    expect(body).toHaveProperty("otp_code", "123456");
  });
  it("chave ausente → no-op", () => {
    expect(redactFields({ ok: true }, ["otp_code"])).toEqual({ ok: true });
  });
  it("lista vazia → retorna igual", () => {
    const body = { ok: true, otp_code: "1" };
    expect(redactFields(body, [])).toBe(body);
  });
});