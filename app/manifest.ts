import type { MetadataRoute } from "next";

/**
 * Web App Manifest do PWA Entregador (ADR-023 Fase 1 / D4). Doc Next 16:
 * app/api-reference/file-conventions/metadata/manifest. start_url=/driver.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "ViO10 Entregador",
    short_name: "ViO10",
    description: "App do entregador ViO10 — fretes rápidos locais.",
    start_url: "/driver",
    scope: "/",
    display: "standalone",
    orientation: "portrait",
    background_color: "#ffffff",
    theme_color: "#3b6df6",
    categories: ["navigation", "business", "productivity"],
    icons: [
      { src: "/icon.svg", sizes: "any", type: "image/svg+xml", purpose: "any" },
      { src: "/icon-maskable.svg", sizes: "any", type: "image/svg+xml", purpose: "maskable" },
    ],
  };
}