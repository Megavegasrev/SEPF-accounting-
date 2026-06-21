import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

/** Simple placeholder for sections delivered in later phases. */
export function Placeholder({ title, description }: { title: string; description?: string }) {
  return (
    <section className="space-y-3">
      <h1 className="text-2xl font-semibold tracking-tight">{title}</h1>
      <Card>
        <CardHeader>
          <CardTitle className="text-base font-medium text-muted-foreground">Bientôt disponible</CardTitle>
        </CardHeader>
        <CardContent className="text-sm text-muted-foreground">
          {description ?? "Cette section sera disponible dans une prochaine étape."}
        </CardContent>
      </Card>
    </section>
  );
}
