import { describe, it, expect } from "vitest";
import { validateCreateDelivery } from "./deliveries";

const validBase = {
  organization_id: "org-1",
  business_id: "biz-1",
  business_location_id: "loc-1",
  pickup_address: "Rua A, 1",
  pickup_lat: -22.0,
  pickup_lng: -43.0,
  delivery_address: "Rua B, 2",
  delivery_lat: -22.1,
  delivery_lng: -43.1,
  vehicle_required: "motorcycle",
  origin: "whatsapp",
  external_reference: "ext-1",
  items: [{ description: "caixa", quantity: 2 }],
};

describe("validateCreateDelivery", () => {
  it("aceita input válido mínimo", () => {
    expect(validateCreateDelivery(validBase)).toEqual({ valid: true });
  });

  it("aceita car + priority urgent + opcionais", () => {
    expect(validateCreateDelivery({ ...validBase, vehicle_required: "car", priority: "urgent", notes: "x" })).toEqual({ valid: true });
  });

  it("rejeita body não-objeto", () => {
    expect(validateCreateDelivery(null)).toEqual({ valid: false, reason: "invalid_param" });
    expect(validateCreateDelivery("x")).toEqual({ valid: false, reason: "invalid_param" });
  });

  it("rejeita campo obrigatório ausente/vazio", () => {
    for (const k of ["organization_id", "pickup_address", "external_reference", "items"] as const) {
      const copy = { ...validBase, [k]: "" };
      expect(validateCreateDelivery(copy)).toEqual({ valid: false, reason: "invalid_param" });
    }
    const noOrg = { ...validBase } as Record<string, unknown>;
    delete noOrg.business_id;
    expect(validateCreateDelivery(noOrg)).toEqual({ valid: false, reason: "invalid_param" });
  });

  it("rejeita vehicle_required inválido", () => {
    expect(validateCreateDelivery({ ...validBase, vehicle_required: "truck" })).toEqual({ valid: false, reason: "invalid_param" });
  });

  it("rejeita origin inválido", () => {
    expect(validateCreateDelivery({ ...validBase, origin: "telepathy" })).toEqual({ valid: false, reason: "invalid_param" });
  });

  it("rejeita priority inválido", () => {
    expect(validateCreateDelivery({ ...validBase, priority: "yesterday" })).toEqual({ valid: false, reason: "invalid_param" });
  });

  it("rejeita items vazio ou não-array", () => {
    expect(validateCreateDelivery({ ...validBase, items: [] })).toEqual({ valid: false, reason: "invalid_param" });
    expect(validateCreateDelivery({ ...validBase, items: "caixa" })).toEqual({ valid: false, reason: "invalid_param" });
  });

  it("rejeita item com quantity <= 0 ou description vazia", () => {
    expect(validateCreateDelivery({ ...validBase, items: [{ description: "caixa", quantity: 0 }] })).toEqual({ valid: false, reason: "invalid_param" });
    expect(validateCreateDelivery({ ...validBase, items: [{ description: "", quantity: 1 }] })).toEqual({ valid: false, reason: "invalid_param" });
    expect(validateCreateDelivery({ ...validBase, items: [{ description: "caixa" }] })).toEqual({ valid: false, reason: "invalid_param" });
  });
});