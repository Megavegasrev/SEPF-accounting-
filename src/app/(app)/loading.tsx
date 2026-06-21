import { Loader2 } from "lucide-react";
export default function Loading() {
  return (
    <div className="flex min-h-[40vh] items-center justify-center text-muted-foreground" role="status" aria-live="polite">
      <Loader2 className="size-6 animate-spin" />
      <span className="sr-only">Chargement…</span>
    </div>
  );
}
