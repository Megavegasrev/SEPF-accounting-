import { requireUser } from "@/lib/auth/server";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

export default async function AccueilPage() {
  const user = await requireUser();
  return (
    <section className="space-y-4">
      <div>
        <h1 className="text-2xl font-semibold tracking-tight">Bonjour, {user.full_name}</h1>
        <p className="text-sm text-muted-foreground">Rôle : {user.role_name}</p>
      </div>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Tableau de bord</CardTitle>
        </CardHeader>
        <CardContent className="text-sm text-muted-foreground">
          Votre tableau de bord personnalisé sera disponible à la prochaine étape (Phase 3).
          Utilisez la navigation en bas de l'écran et le bouton « + » pour accéder aux actions
          autorisées par votre rôle.
        </CardContent>
      </Card>
    </section>
  );
}
