import { clsx, type ClassValue } from "clsx";
import { twMerge } from "tailwind-merge";

/** `cn` — merge condicional de classes Tailwind (shadcn/ui). */
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs));
}

/** Formata inteiros de centavos → "R$ 10,90" (ADR-008: dinheiro sempre em centavos). */
export function formatBRL(cents: number | null | undefined): string {
  if (cents == null) return "—";
  const reais = Math.trunc(cents / 100);
  const centavos = Math.abs(cents % 100);
  return `R$ ${reais},${String(centavos).padStart(2, "0")}`;
}

/** Distância em metros → "1,2 km" ou "850 m". */
export function formatDistance(meters: number | null | undefined): string {
  if (meters == null) return "—";
  if (meters < 1000) return `${Math.round(meters)} m`;
  return `${(meters / 1000).toLocaleString("pt-BR", { maximumFractionDigits: 1 })} km`;
}

/** Duração em segundos → "12 min". */
export function formatDuration(seconds: number | null | undefined): string {
  if (seconds == null) return "—";
  const min = Math.round(seconds / 60);
  return `${min} min`;
}