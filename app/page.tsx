import { redirect } from "next/navigation";

// Home redireciona à superfície do entregador (ADR-023 Fase 4). Middleware protege
// /driver: sem sessão → 307 /auth/login. Admin/business chegam a /driver e daí a
// landing por papel (Sessão 18/19 terão /admin, /business diretos).
export default function HomePage(): never {
  redirect("/driver");
}