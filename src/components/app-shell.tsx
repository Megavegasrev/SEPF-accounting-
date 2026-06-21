import type { CurrentUser } from "@/lib/types";
import { UserMenu } from "@/components/user-menu";
import { BottomNav } from "@/components/bottom-nav";
import { Fab } from "@/components/fab";

/** Mobile-first application shell: top bar, content, FAB and bottom navigation. */
export function AppShell({ user, children }: { user: CurrentUser; children: React.ReactNode }) {
  return (
    <div className="min-h-dvh bg-muted/30">
      <header className="sticky top-0 z-40 flex h-14 items-center justify-between border-b bg-background px-4">
        <div className="flex items-center gap-2">
          <span className="inline-block size-6 rounded bg-primary" aria-hidden />
          <span className="font-semibold">SEPF Trésorerie</span>
        </div>
        <UserMenu name={user.full_name} roleName={user.role_name} />
      </header>
      <main className="mx-auto w-full max-w-md px-4 pb-24 pt-4">{children}</main>
      <Fab permissions={user.permissions} />
      <BottomNav />
    </div>
  );
}
