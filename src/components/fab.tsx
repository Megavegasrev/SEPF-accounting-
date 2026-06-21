"use client";
import { Plus } from "lucide-react";
import { toast } from "sonner";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu, DropdownMenuTrigger, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator,
} from "@/components/ui/dropdown-menu";
import { FAB_ACTIONS } from "@/lib/nav";
import { can } from "@/lib/permissions";

/** Floating "+" with actions filtered by the user's permissions. */
export function Fab({ permissions }: { permissions: readonly string[] }) {
  const actions = FAB_ACTIONS.filter((a) => can(permissions, a.permission));
  if (actions.length === 0) return null;
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          size="icon"
          className="fixed bottom-20 right-4 z-40 h-14 w-14 rounded-full shadow-lg"
          aria-label="Actions rapides"
        >
          <Plus className="size-6" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" side="top" className="mb-2">
        <DropdownMenuLabel>Actions rapides</DropdownMenuLabel>
        <DropdownMenuSeparator />
        {actions.map((a) => {
          const Icon = a.icon;
          return (
            <DropdownMenuItem key={a.id} onSelect={() => toast.info(`${a.label} — bientôt disponible`)}>
              <Icon />
              {a.label}
            </DropdownMenuItem>
          );
        })}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
