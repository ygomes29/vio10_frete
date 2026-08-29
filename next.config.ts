import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Route Handlers são a superfície de API (ADR-018 D5 / ADR-019).
  // Sem UI nesta fase (Sessões 17-19).
  experimental: {
    // serverActions são só para ações originadas no próprio frontend (BACKEND §3).
    // n8n/DataCrazy nunca dependem de Server Actions.
  },
};

export default nextConfig;