import { redirect } from "next/navigation";
import { getCurrentUserOrNull } from "@/lib/auth/server";
import { LoginForm } from "@/components/login-form";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export default async function LoginPage() {
  const user = await getCurrentUserOrNull();
  if (user) redirect("/");
  return (
    <main className="flex min-h-dvh items-center justify-center bg-muted/40 px-4">
      <Card className="w-full max-w-sm">
        <CardHeader className="space-y-2 text-center">
          <div className="mx-auto flex size-12 items-center justify-center rounded-xl bg-primary text-primary-foreground font-bold">
            SE
          </div>
          <CardTitle className="text-xl">SEPF Trésorerie</CardTitle>
          <CardDescription>Connectez-vous pour accéder à votre espace.</CardDescription>
        </CardHeader>
        <CardContent>
          <LoginForm />
        </CardContent>
      </Card>
    </main>
  );
}
