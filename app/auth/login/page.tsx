"use client";

import { useActionState } from "react";
import { signIn, type SignInState } from "./actions";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

export default function LoginPage() {
  const [state, formAction, pending] = useActionState<SignInState, FormData>(signIn, {});

  return (
    <main className="flex min-h-svh flex-col items-center justify-center bg-muted/40 p-4">
      <Card className="w-full max-w-sm">
        <CardHeader className="space-y-3 text-center">
          <div className="mx-auto flex h-12 w-12 items-center justify-center rounded-xl bg-primary text-2xl font-black text-primary-foreground">
            V
          </div>
          <CardTitle className="text-2xl">ViO10 Entregador</CardTitle>
          <CardDescription>Entre para receber oportunidades de frete.</CardDescription>
        </CardHeader>
        <CardContent>
          <form action={formAction} className="space-y-4" autoComplete="on">
            <div className="space-y-2">
              <Label htmlFor="email">Email</Label>
              <Input
                id="email"
                name="email"
                type="email"
                inputMode="email"
                autoComplete="email"
                placeholder="voce@email.com"
                required
                defaultValue={state.email ?? ""}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="password">Senha</Label>
              <Input
                id="password"
                name="password"
                type="password"
                autoComplete="current-password"
                required
              />
            </div>
            {state.error ? (
              <p role="alert" className="text-sm font-medium text-destructive">
                {state.error}
              </p>
            ) : null}
            <Button type="submit" size="lg" className="w-full" disabled={pending}>
              {pending ? "Entrando…" : "Entrar"}
            </Button>
          </form>
          <p className="mt-4 text-center text-xs text-muted-foreground">
            Não tem conta? Peça acesso a quem gerencia seu cadastro.
          </p>
        </CardContent>
      </Card>
    </main>
  );
}