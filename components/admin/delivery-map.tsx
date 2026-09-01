"use client";

import { useEffect, useRef } from "react";
import { apiGet } from "@/lib/client/fetcher";
import "leaflet/dist/leaflet.css";

/**
 * Mapa da corrida — **vanilla Leaflet + OSM** (Sessão 18 / ADR-024 D3). Client-only.
 * Sem `react-leaflet` (fricção React 19). Tiles OpenStreetMap, **zero credenciais**
 * (não depende de Google). Marcadores coleta (laranja de marca) / destino / entregador
 * + polyline coleta→destino. **Polling** `/api/admin/deliveries/{id}/positions` 15s
 * em foreground p/ atualizar o marcador do entregador (parse GeoJSON no backend).
 *
 * `leaflet` é importado dinamicamente dentro do `useEffect` (SSR-safe — leaflet toca
 * `window` no import). `divIcon` com SVG inline evita o bug de path do ícone default
 * do Leaflet no bundler.
 */
type Point = { lat: number; lng: number };

type PositionsData = {
  id: string;
  status: string | null;
  pickup: Point;
  delivery: Point;
  driver: {
    full_name: string | null;
    position: Point | null;
    captured_at: string | null;
    accuracy_m: number | null;
  } | null;
};

export function DeliveryMap({
  deliveryId,
  pickup,
  delivery,
  positionsUrl,
}: {
  deliveryId: string;
  pickup: Point;
  delivery: Point;
  /** URL de polling das posições (default `/api/admin/deliveries/{id}/positions`).
   *  Sessão 19: parametrizado p/ reuso no portal business (`/api/business/deliveries/
   *  {id}/positions`). */
  positionsUrl?: string;
}) {
  const containerRef = useRef<HTMLDivElement | null>(null);
  const positionsEndpoint = positionsUrl ?? `/api/admin/deliveries/${deliveryId}/positions`;

  useEffect(() => {
    if (!containerRef.current) return;
    let map: import("leaflet").Map | null = null;
    let driverMarker: import("leaflet").Marker | null = null;
    let cancelled = false;

    async function init() {
      const L = await import("leaflet");
      if (cancelled || !containerRef.current) return;

      map = L.map(containerRef.current, {
        scrollWheelZoom: false,
        attributionControl: true,
      }).setView([(pickup.lat + delivery.lat) / 2, (pickup.lng + delivery.lng) / 2], 14);

      L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19,
        attribution: "© OpenStreetMap",
      }).addTo(map);

      const pickupIcon = L.divIcon({
        className: "",
        html: '<div style="background:#fe7845;color:#1a1207;border-radius:50%;width:22px;height:22px;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:12px;border:2px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.4)">A</div>',
        iconSize: [22, 22],
        iconAnchor: [11, 11],
      });
      const deliveryIcon = L.divIcon({
        className: "",
        html: '<div style="background:#1f2937;color:#fff;border-radius:50%;width:22px;height:22px;display:flex;align-items:center;justify-content:center;font-weight:700;font-size:12px;border:2px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.4)">B</div>',
        iconSize: [22, 22],
        iconAnchor: [11, 11],
      });

      const pickupM = L.marker([pickup.lat, pickup.lng], { icon: pickupIcon }).addTo(map);
      const deliveryM = L.marker([delivery.lat, delivery.lng], { icon: deliveryIcon }).addTo(map);
      pickupM.bindPopup("Coleta");
      deliveryM.bindPopup("Entrega");
      L.polyline(
        [
          [pickup.lat, pickup.lng],
          [delivery.lat, delivery.lng],
        ],
        { color: "#fe7845", weight: 3, opacity: 0.7, dashArray: "6 6" },
      ).addTo(map);

      const driverIcon = L.divIcon({
        className: "",
        html: '<div style="background:#0ea5e9;color:#fff;border-radius:50%;width:20px;height:20px;display:flex;align-items:center;justify-content:center;border:2px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.4)">●</div>',
        iconSize: [20, 20],
        iconAnchor: [10, 10],
      });

      const bounds = L.latLngBounds([
        [pickup.lat, pickup.lng],
        [delivery.lat, delivery.lng],
      ]);

      async function refresh() {
        if (typeof document !== "undefined" && document.visibilityState !== "visible") return;
        const r = await apiGet<PositionsData>(positionsEndpoint);
        if (!r.ok || !r.data || !map) return;
        const d = r.data.driver;
        if (d?.position) {
          const ll: [number, number] = [d.position.lat, d.position.lng];
          if (driverMarker) {
            driverMarker.setLatLng(ll);
          } else {
            driverMarker = L.marker(ll, { icon: driverIcon }).addTo(map);
            driverMarker.bindPopup(`Entregador${d.full_name ? ": " + d.full_name : ""}`);
          }
          bounds.extend(ll);
          map.fitBounds(bounds, { padding: [40, 40] });
        }
      }

      void refresh();
      const intervalId = window.setInterval(refresh, 15_000);
      // cleanup armazena intervalId no closure externo via ref externo.
      (init as unknown as { _intervalId?: number })._intervalId = intervalId;
    }

    void init();

    return () => {
      cancelled = true;
      const intervalId = (init as unknown as { _intervalId?: number })._intervalId;
      if (intervalId) window.clearInterval(intervalId);
      if (map) map.remove();
      map = null;
    };
  }, [deliveryId, pickup.lat, pickup.lng, delivery.lat, delivery.lng, positionsEndpoint]);

  return <div ref={containerRef} className="h-[420px] w-full rounded-md border" role="img" aria-label="Mapa da corrida" />;
}