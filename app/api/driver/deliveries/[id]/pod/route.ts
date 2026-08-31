import { handleUserPost } from "@/lib/api/user-handler";
import {
  validatePodBody,
  submitProofOfDelivery,
  type SubmitPodInput,
} from "@/lib/services/driver";

/**
 * `POST /api/driver/deliveries/{id}/pod` → `submit_proof_of_delivery`
 * (driver-scoped, ADR-017). Cookie JWT (user-scoped). **Não transita** — emite
 * `pod_submitted`; a transição `delivered` é system via `confirm_delivery`.
 * `sensitive: true` (ADR-020 D9): não loga otp_code/payload (PII/secret).
 * Foto: o PWA faz upload direto ao bucket `pod-photos` (RLS Sessão 12); aqui
 * recebemos só `storage_path`.
 */
export async function POST(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  const { id } = await params;
  return handleUserPost(request, {
    eventType: "driver.pod",
    sensitive: true,
    validate: (b) => {
      const r = validatePodBody(b);
      return r.valid ? null : r.reason;
    },
    run: async (correlationId, body, ctx) => {
      const b = body as {
        pod_type: SubmitPodInput["podType"];
        storage_path?: string | null;
        otp_code?: string | null;
        receiver_name?: string | null;
        location_lat?: number | null;
        location_lng?: number | null;
        notes?: string | null;
      };
      return submitProofOfDelivery(ctx.client, {
        deliveryId: id,
        podType: b.pod_type,
        storagePath: b.storage_path ?? null,
        otpCode: b.otp_code ?? null,
        receiverName: b.receiver_name ?? null,
        locationLat: b.location_lat ?? null,
        locationLng: b.location_lng ?? null,
        notes: b.notes ?? null,
      }, correlationId);
    },
  });
}