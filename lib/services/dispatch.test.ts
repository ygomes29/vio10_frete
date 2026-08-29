import { describe, it, expect } from "vitest";
import { validateDispatchRoundBody } from "./dispatch";

const validBody = {
  search_radius_m: 3000,
  max_candidates: 10,
  driver_offer_cents: 1090,
  response_window_seconds: 60,
};

describe("validateDispatchRoundBody", () => {
  it("aceita body válido (sem delivery_request_id — vem do path)", () => {
    expect(validateDispatchRoundBody(validBody)).toEqual({ valid: true });
  });

  it("aceita max_location_age_seconds opcional", () => {
    expect(validateDispatchRoundBody({ ...validBody, max_location_age_seconds: 120 })).toEqual({ valid: true });
  });

  it("rejeita não-objeto", () => {
    expect(validateDispatchRoundBody(null)).toEqual({ valid: false, reason: "invalid_param" });
  });

  it("rejeita campo obrigatório ausente", () => {
    const copy = { ...validBody } as Record<string, unknown>;
    delete copy.driver_offer_cents;
    expect(validateDispatchRoundBody(copy)).toEqual({ valid: false, reason: "invalid_param" });
  });

  it("rejeita valores não-positivos", () => {
    expect(validateDispatchRoundBody({ ...validBody, search_radius_m: 0 })).toEqual({ valid: false, reason: "invalid_param" });
    expect(validateDispatchRoundBody({ ...validBody, max_candidates: -1 })).toEqual({ valid: false, reason: "invalid_param" });
    expect(validateDispatchRoundBody({ ...validBody, response_window_seconds: 0 })).toEqual({ valid: false, reason: "invalid_param" });
  });

  it("aceita driver_offer_cents == 0 (corrida cortesia)", () => {
    expect(validateDispatchRoundBody({ ...validBody, driver_offer_cents: 0 })).toEqual({ valid: true });
  });

  it("rejeita driver_offer_cents negativo", () => {
    expect(validateDispatchRoundBody({ ...validBody, driver_offer_cents: -1 })).toEqual({ valid: false, reason: "invalid_param" });
  });

  it("rejeita max_location_age_seconds não-positivo", () => {
    expect(validateDispatchRoundBody({ ...validBody, max_location_age_seconds: 0 })).toEqual({ valid: false, reason: "invalid_param" });
  });
});