import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { RpcResult } from "@/lib/rpc/result";

// Reuso direto: as queries de lista/detalhe/posições são RLS-agnostic — o gate de authz
// (membership) está no handler (`handleBusinessGet`), e a RLS (`can_view_delivery_request`/
// `my_org_ids()`) escopa ao tenant. Para business, `listDeliveries` é chamado **sem**
// `businessId` (RLS escopa). Sessão 19 / ADR-025 D5.
export {
  listDeliveries,
  getDeliveryDetail,
  getDeliveryPositions,
  parsePointPosition,
  type ListDeliveriesParams,
  type Point,
} from "./admin-reads";

const ok = <T extends Record<string, unknown>>(payload: T): RpcResult => ({
  ok: true,
  reason: null,
  ...payload,
});
const fail = (reason: string): RpcResult => ({ ok: false, reason });

function isPgError(error: unknown, fallback = "internal_error"): string {
  if (!error) return fallback;
  const msg = String((error as { message?: string }).message ?? "");
  if (/policy|permission|denied/i.test(msg)) return "not_authorized";
  return fallback;
}

/** Status ativos (não-terminais) da máquina de entrega (ADR-016). */
const ACTIVE_STATUSES = [
  "draft",
  "quoted",
  "searching_driver",
  "assigned",
  "driver_to_pickup",
  "at_pickup",
  "picked_up",
  "in_transit",
] as const;
const TERMINAL_STATUSES = ["delivered", "cancelled", "failed", "expired"] as const;

/** Janela de retrospecção do overview (corridas ativas + terminais recentes). */
const OVERVIEW_WINDOW_HOURS = 72;
/** Limite de rows lidas p/ agregação client-side (volume MVP por tenant). */
const OVERVIEW_MAX_ROWS = 1000;

// ---- GET /api/business/me ----

type MembershipRow = { organization_id: string; role: string };
type OrgRow = { id: string; name: string; document: string | null };
type BusinessRow = { id: string; organization_id: string; name: string; status: string };
type LocationRow = {
  id: string;
  business_id: string;
  label: string | null;
  address: string;
  is_active: boolean;
};

/**
 * Resolve o contexto do business user: memberships (RPC DEFINER) + organizations/
 * businesses/business_locations (leitura direta user-scoped, RLS `orgs_sel`/`biz_sel`/
 * `bizloc_sel` escopa por `my_org_ids()`). Sessão 19 / ADR-025 D1.
 */
export async function getBusinessMe(client: SupabaseClient): Promise<RpcResult> {
  const [memRes, orgRes, bizRes, locRes] = await Promise.all([
    client.rpc("my_org_memberships"),
    client.from("organizations").select("id, name, document"),
    client.from("businesses").select("id, organization_id, name, status"),
    client.from("business_locations").select("id, business_id, label, address, is_active"),
  ]);

  if (memRes.error) return fail(isPgError(memRes.error));
  if (orgRes.error) return fail(isPgError(orgRes.error));
  if (bizRes.error) return fail(isPgError(bizRes.error));
  if (locRes.error) return fail(isPgError(locRes.error));

  const memberships = (memRes.data ?? []) as MembershipRow[];
  const organizations = (orgRes.data ?? []) as OrgRow[];
  const businesses = (bizRes.data ?? []) as BusinessRow[];
  const locations = (locRes.data ?? []) as LocationRow[];

  return ok({
    memberships,
    organizations,
    businesses,
    locations,
  });
}

// ---- GET /api/business/overview ----

type OverviewRow = {
  id: string;
  status: string;
  created_at: string;
  delivered_at: string | null;
  cancelled_at: string | null;
  failed_reason: string | null;
  cancelled_reason: string | null;
  delivery_quotes?:
    | { customer_price_cents?: number | null }
    | { customer_price_cents?: number | null }[]
    | null;
};

/**
 * Overview do tenant: corridas ativas + terminais recentes (janela 72h), entregues hoje
 * (volume em centavos inteiros), falhas recentes. **Sem** KPI de entregadores
 * (conceito platform-wide/admin — o business owner olha pras próprias corridas). RLS
 * (`delreq_sel`→`can_view_delivery_request`→`my_org_ids()`) escopa ao tenant
 * automaticamente. Sessão 19 / ADR-025 D8.
 */
export async function getBusinessOverview(client: SupabaseClient): Promise<RpcResult> {
  const since = new Date(Date.now() - OVERVIEW_WINDOW_HOURS * 3600_000).toISOString();

  const { data, error } = await client
    .from("delivery_requests")
    .select(
      "id, status, created_at, delivered_at, cancelled_at, failed_reason, cancelled_reason, delivery_quotes(customer_price_cents)",
    )
    .gte("created_at", since)
    .order("created_at", { ascending: false })
    .limit(OVERVIEW_MAX_ROWS);

  if (error) return fail(isPgError(error));

  const rows = (data ?? []) as OverviewRow[];

  const byStatus: Record<string, number> = {};
  for (const r of rows) byStatus[r.status] = (byStatus[r.status] ?? 0) + 1;

  const active: Record<string, number> = {};
  for (const s of ACTIVE_STATUSES) if (byStatus[s]) active[s] = byStatus[s];
  const terminal: Record<string, number> = {};
  for (const s of TERMINAL_STATUSES) if (byStatus[s]) terminal[s] = byStatus[s];

  // Volume do dia (delivered hoje — soma customer_price_cents em centavos inteiros).
  const dayStart = new Date();
  dayStart.setHours(0, 0, 0, 0);
  let deliveredTodayCount = 0;
  let deliveredTodayCents = 0;
  for (const r of rows) {
    if (r.status !== "delivered" || !r.delivered_at) continue;
    if (new Date(r.delivered_at) < dayStart) continue;
    deliveredTodayCount += 1;
    const q = Array.isArray(r.delivery_quotes) ? r.delivery_quotes[0] : r.delivery_quotes;
    deliveredTodayCents += Number(q?.customer_price_cents) || 0;
  }

  // Falhas recentes (cancelled/failed/expired na janela, últimas 20).
  const failures = rows
    .filter(
      (r) =>
        r.status === "cancelled" || r.status === "failed" || r.status === "expired",
    )
    .slice(0, 20)
    .map((r) => ({
      id: r.id,
      status: r.status,
      created_at: r.created_at,
      cancelled_at: r.cancelled_at,
      reason: r.failed_reason ?? r.cancelled_reason ?? null,
    }));

  return ok({
    window_hours: OVERVIEW_WINDOW_HOURS,
    deliveries_by_status: { active, terminal },
    delivered_today: {
      count: deliveredTodayCount,
      total_cents: deliveredTodayCents,
    },
    failures,
  });
}