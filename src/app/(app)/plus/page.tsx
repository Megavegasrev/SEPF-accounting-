import { requireUser } from "@/lib/auth/server";
import { PLUS_LINKS } from "@/lib/nav";
import { can } from "@/lib/permissions";
import { Card } from "@/components/ui/card";

export default async function PlusPage() {
  const user = await requireUser();
  const links = PLUS_LINKS.filter((l) => !l.permission || can(user.permissions, l.permission));
  return (
    <section className="space-y-4">
      <h1 className="text-2xl font-semibold tracking-tight">Plus</h1>
      <Card className="divide-y">
        {links.length === 0 && (
          <div className="p-4 text-sm text-muted-foreground">Aucune section supplémentaire pour votre rôle.</div>
        )}
        {links.map((l) => {
          const Icon = l.icon;
          return (
            <div key={l.label} className="flex items-center justify-between p-4">
              <div className="flex items-center gap-3">
                <Icon className="size-5 text-muted-foreground" />
                <span className="text-sm font-medium">{l.label}</span>
              </div>
              <span className="rounded-full bg-muted px-2 py-0.5 text-xs text-muted-foreground">Bientôt</span>
            </div>
          );
        })}
      </Card>
    </section>
  );
}
