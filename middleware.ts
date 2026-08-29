import { NextResponse, type NextRequest } from "next/server";

// Middleware mínimo (Sessão 14). A wiring completa de cookie/refresh (ADR-010 D6)
// vem com os endpoints user/driver-facing na Sessão 15/17. Por ora, apenas deixa
// /api/* passar — Route Handlers fazem sua própria auth (internal-auth p/ system,
// cookie p/ user).

export function middleware(_request: NextRequest) {
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};