import { describe, it, expect } from "vitest";
import {
  validateRespondOfferBody,
  validatePodBody,
  validateTransitionBody,
  validateAvailabilityBody,
  validateDriverLocationBody,
} from "./driver";

describe("validateRespondOfferBody", () => {
  it("aceita accept válido", () => {
    expect(validateRespondOfferBody({ driver_id: "d1", response_type: "accept" })).toEqual({ valid: true });
  });
  it("aceita counter_bid c/ bid_amount_cents > 0", () => {
    expect(validateRespondOfferBody({ driver_id: "d1", response_type: "counter_bid", bid_amount_cents: 1500 })).toEqual({ valid: true });
  });
  it("rejeita counter_bid sem bid_amount_cents", () => {
    expect(validateRespondOfferBody({ driver_id: "d1", response_type: "counter_bid" })).toEqual({ valid: false, reason: "invalid_bid_amount" });
  });
  it("rejeita counter_bid c/ bid_amount_cents <= 0", () => {
    expect(validateRespondOfferBody({ driver_id: "d1", response_type: "counter_bid", bid_amount_cents: 0 })).toEqual({ valid: false, reason: "invalid_bid_amount" });
  });
  it("rejeita response_type inválido", () => {
    expect(validateRespondOfferBody({ driver_id: "d1", response_type: "maybe" })).toEqual({ valid: false, reason: "invalid_response_type" });
  });
  it("rejeita sem driver_id", () => {
    expect(validateRespondOfferBody({ response_type: "accept" })).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita body não-objeto", () => {
    expect(validateRespondOfferBody(null)).toEqual({ valid: false, reason: "invalid_param" });
    expect(validateRespondOfferBody("x")).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("aceita decline (sem bid_amount)", () => {
    expect(validateRespondOfferBody({ driver_id: "d1", response_type: "decline" })).toEqual({ valid: true });
  });
});

describe("validatePodBody", () => {
  it("delivery c/ foto + receiver_name", () => {
    expect(validatePodBody({ pod_type: "delivery", storage_path: "p.jpg", receiver_name: "R" })).toEqual({ valid: true });
  });
  it("delivery c/ otp + receiver_name", () => {
    expect(validatePodBody({ pod_type: "delivery", otp_code: "123456", receiver_name: "R" })).toEqual({ valid: true });
  });
  it("delivery sem foto/otp → invalid_pod", () => {
    expect(validatePodBody({ pod_type: "delivery", receiver_name: "R" })).toEqual({ valid: false, reason: "invalid_pod" });
  });
  it("delivery sem receiver_name → invalid_pod", () => {
    expect(validatePodBody({ pod_type: "delivery", storage_path: "p.jpg" })).toEqual({ valid: false, reason: "invalid_pod" });
  });
  it("pickup c/ notes", () => {
    expect(validatePodBody({ pod_type: "pickup", notes: "ok" })).toEqual({ valid: true });
  });
  it("pickup sem nada → invalid_pod", () => {
    expect(validatePodBody({ pod_type: "pickup" })).toEqual({ valid: false, reason: "invalid_pod" });
  });
  it("pod_type inválido → invalid_pod", () => {
    expect(validatePodBody({ pod_type: "other" })).toEqual({ valid: false, reason: "invalid_pod" });
  });
  it("location não-numérico → invalid_param", () => {
    expect(validatePodBody({ pod_type: "pickup", notes: "x", location_lat: "abc" })).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("location numérico válido", () => {
    expect(validatePodBody({ pod_type: "pickup", notes: "x", location_lat: -23, location_lng: -46 })).toEqual({ valid: true });
  });
});

describe("validateTransitionBody", () => {
  for (const s of ["driver_to_pickup", "at_pickup", "picked_up", "in_transit"]) {
    it(`aceita ${s}`, () => {
      expect(validateTransitionBody({ to_status: s })).toEqual({ valid: true });
    });
  }
  it("rejeita delivered (driver não pode)", () => {
    expect(validateTransitionBody({ to_status: "delivered" })).toEqual({ valid: false, reason: "invalid_transition" });
  });
  it("rejeita cancelled (driver não pode)", () => {
    expect(validateTransitionBody({ to_status: "cancelled" })).toEqual({ valid: false, reason: "invalid_transition" });
  });
  it("rejeita sem to_status", () => {
    expect(validateTransitionBody({})).toEqual({ valid: false, reason: "invalid_transition" });
  });
  it("metadata não-objeto → invalid_param", () => {
    expect(validateTransitionBody({ to_status: "at_pickup", metadata: "x" })).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("metadata objeto válido", () => {
    expect(validateTransitionBody({ to_status: "at_pickup", metadata: { k: 1 } })).toEqual({ valid: true });
  });
});

describe("validateAvailabilityBody", () => {
  for (const s of ["available", "paused", "offline"]) {
    it(`aceita status ${s}`, () => {
      expect(validateAvailabilityBody({ status: s })).toEqual({ valid: true });
    });
  }
  it("rejeita offered (sistema, não driver)", () => {
    expect(validateAvailabilityBody({ status: "offered" })).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita busy (sistema, não driver)", () => {
    expect(validateAvailabilityBody({ status: "busy" })).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita sem status", () => {
    expect(validateAvailabilityBody({})).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita driver_id não-string", () => {
    expect(validateAvailabilityBody({ status: "available", driver_id: 123 })).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("reason string válido", () => {
    expect(validateAvailabilityBody({ status: "paused", reason: "almoco" })).toEqual({ valid: true });
  });
});

describe("validateDriverLocationBody", () => {
  it("aceita lat/lng/captured_at válidos", () => {
    expect(
      validateDriverLocationBody({ latitude: -23.6, longitude: -46.7, captured_at: "2026-08-31T00:00:00Z" }),
    ).toEqual({ valid: true });
  });
  it("aceita campos opcionais finitos", () => {
    expect(
      validateDriverLocationBody({
        latitude: 0,
        longitude: 0,
        captured_at: "2026-08-31T00:00:00Z",
        accuracy_m: 10,
        heading_deg: 90,
        speed_mps: 5,
      }),
    ).toEqual({ valid: true });
  });
  it("rejeita lat fora do range", () => {
    expect(
      validateDriverLocationBody({ latitude: 91, longitude: 0, captured_at: "x" }),
    ).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita lng fora do range", () => {
    expect(
      validateDriverLocationBody({ latitude: 0, longitude: 181, captured_at: "x" }),
    ).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita lat não-finito (NaN)", () => {
    expect(
      validateDriverLocationBody({ latitude: NaN, longitude: 0, captured_at: "x" }),
    ).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita sem captured_at", () => {
    expect(
      validateDriverLocationBody({ latitude: 0, longitude: 0 }),
    ).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("rejeita accuracy_m não-numérico", () => {
    expect(
      validateDriverLocationBody({ latitude: 0, longitude: 0, captured_at: "x", accuracy_m: "abc" }),
    ).toEqual({ valid: false, reason: "invalid_param" });
  });
  it("aceita opcionais null/undefined", () => {
    expect(
      validateDriverLocationBody({ latitude: 0, longitude: 0, captured_at: "x", accuracy_m: null, heading_deg: undefined }),
    ).toEqual({ valid: true });
  });
  it("rejeita body não-objeto", () => {
    expect(validateDriverLocationBody(null)).toEqual({ valid: false, reason: "invalid_param" });
    expect(validateDriverLocationBody("x")).toEqual({ valid: false, reason: "invalid_param" });
  });
});