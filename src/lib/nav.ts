import { Home, FileText, Wallet, History, MoreHorizontal,
  PlusCircle, ArrowDownToLine, ArrowLeftRight, Users, Settings, Banknote,
  Landmark, PiggyBank, FileBarChart, type LucideIcon } from "lucide-react";
import { PERMISSIONS, type PermissionCode } from "@/lib/permissions";

export interface NavItem { href: string; label: string; icon: LucideIcon; }

/** Bottom navigation (mobile-first). Targets exist as placeholder pages. */
export const BOTTOM_NAV: readonly NavItem[] = [
  { href: "/", label: "Accueil", icon: Home },
  { href: "/demandes", label: "Demandes", icon: FileText },
  { href: "/tresorerie", label: "Trésorerie", icon: Wallet },
  { href: "/historique", label: "Historique", icon: History },
  { href: "/plus", label: "Plus", icon: MoreHorizontal },
];

export interface QuickAction { id: string; label: string; icon: LucideIcon; permission: PermissionCode; }

/** Floating "+" actions, filtered by permission. (Workflows arrive in Phase 4.) */
export const FAB_ACTIONS: readonly QuickAction[] = [
  { id: "request", label: "Nouvelle demande", icon: PlusCircle, permission: PERMISSIONS.requestCreate },
  { id: "income-small", label: "Nouvelle entrée (petite caisse)", icon: ArrowDownToLine, permission: PERMISSIONS.incomeRecordSmall },
  { id: "income-large", label: "Nouvelle entrée (grande caisse)", icon: ArrowDownToLine, permission: PERMISSIONS.incomeRecordLarge },
  { id: "transfer-stl", label: "Nouveau transfert", icon: ArrowLeftRight, permission: PERMISSIONS.transferInitiateSmallToLarge },
  { id: "transfer-lts", label: "Nouveau transfert", icon: ArrowLeftRight, permission: PERMISSIONS.transferInitiateLargeToSmall },
];

export interface SectionLink { label: string; icon: LucideIcon; permission?: PermissionCode; }

/** "Plus" tab secondary sections, filtered by permission. */
export const PLUS_LINKS: readonly SectionLink[] = [
  { label: "Salaires et avances", icon: Banknote, permission: PERMISSIONS.salaryRead },
  { label: "Investissements", icon: Landmark, permission: PERMISSIONS.investmentRead },
  { label: "Apports en capital", icon: PiggyBank, permission: PERMISSIONS.capitalRead },
  { label: "Prêts", icon: Landmark, permission: PERMISSIONS.loanRead },
  { label: "Emprunts", icon: Landmark, permission: PERMISSIONS.borrowingRead },
  { label: "Rapports", icon: FileBarChart, permission: PERMISSIONS.reportExport },
  { label: "Utilisateurs", icon: Users, permission: PERMISSIONS.usersManage },
  { label: "Paramètres", icon: Settings, permission: PERMISSIONS.settingsManage },
];
