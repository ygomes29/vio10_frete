"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { Select } from "@/components/ui/select";

/**
 * Filtro de status da lista de corridas (Sessão 18 / ADR-024). Navegação
 * server-driven via URL searchParams — ao mudar o select, empurra `?status=`
 * (preservando demais params) e a página re-roda no server. Sem JS extra p/ a
 * tabela em si (Server Component).
 */
const OPTIONS = [
  { value: "", label: "Todos os status" },
  { value: "draft", label: "Rascunho" },
  { value: "quoted", label: "Cotada" },
  { value: "searching_driver", label: "Buscando entregador" },
  { value: "assigned", label: "Atribuída" },
  { value: "driver_to_pickup", label: "A caminho da coleta" },
  { value: "at_pickup", label: "Na coleta" },
  { value: "picked_up", label: "Coletada" },
  { value: "in_transit", label: "Em trânsito" },
  { value: "delivered", label: "Entregue" },
  { value: "cancelled", label: "Cancelada" },
  { value: "failed", label: "Falhou" },
  { value: "expired", label: "Expirada" },
];

export function StatusFilter({ current }: { current: string | null }) {
  const router = useRouter();
  const sp = useSearchParams();

  function onChange(value: string) {
    const params = new URLSearchParams(sp.toString());
    if (value) params.set("status", value);
    else params.delete("status");
    params.delete("offset");
    const qs = params.toString();
    router.push(qs ? `/admin/deliveries?${qs}` : "/admin/deliveries");
  }

  return (
    <Select
      value={current ?? ""}
      onChange={(e) => onChange(e.target.value)}
      className="w-[220px]"
      aria-label="Filtrar por status"
    >
      {OPTIONS.map((o) => (
        <option key={o.value} value={o.value}>
          {o.label}
        </option>
      ))}
    </Select>
  );
}