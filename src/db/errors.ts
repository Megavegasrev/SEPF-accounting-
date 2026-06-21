/**
 * Translates PostgreSQL errors raised by the database functions into clear
 * French business messages for the UI. The database remains the single source
 * of truth for the rules; this only maps its errors to user language.
 */

export class AppError extends Error {
  readonly code: string;
  readonly httpStatus: number;
  override readonly cause?: unknown;
  constructor(message: string, code: string, httpStatus = 400, cause?: unknown) {
    super(message);
    this.name = "AppError";
    this.code = code;
    this.httpStatus = httpStatus;
    this.cause = cause;
  }
}

type PgError = { code?: string; message?: string };

// Ordered message-fragment matchers (checked before the SQLSTATE fallback).
const FRAGMENTS: ReadonlyArray<[RegExp, string]> = [
  [/insufficient (large |small-)?treasury|insufficient balance/i,
    "Solde insuffisant : aucun paiement n'a été effectué."],
  [/already been reversed/i, "Ce mouvement a déjà été contre-passé."],
  [/a reversal cannot itself be reversed/i, "Une contre-passation ne peut pas être contre-passée."],
  [/already been processed|already processed/i, "Cet élément a déjà été traité."],
  [/comment is mandatory/i, "Un commentaire est obligatoire pour un refus ou une demande de correction."],
  [/cause is mandatory/i, "Une cause est obligatoire."],
  [/a reason is mandatory/i, "Un motif est obligatoire."],
  [/exceeds the available/i, "Le montant dépasse l'avance disponible pour ce mois."],
  [/exceed the monthly ceiling/i, "Le plafond mensuel d'avance serait dépassé."],
  [/not permitted to request a salary advance/i, "Vous n'êtes pas autorisé à demander une avance sur salaire."],
  [/no active salary profile/i, "Aucun profil de salaire actif pour cet utilisateur et cette période."],
  [/balance remains due/i, "Solde insuffisant : le solde reste dû."],
  [/no outstanding salary balance/i, "Aucun solde de salaire restant à régler pour ce cycle."],
  [/only expense requests can be corrected/i, "Seules les demandes de dépense peuvent être corrigées."],
  [/cannot be corrected/i, "Une demande déjà payée ou décaissée ne peut pas être corrigée."],
  [/no approved version|no approved version to pay/i, "La demande n'a pas de version approuvée à payer."],
  [/not awaiting first-level approval/i, "Cette version n'attend pas la première validation."],
  [/final approval requires a completed first approval/i, "La validation finale exige d'abord la première validation."],
  [/dedicated payment function/i, "Ce type de demande dispose de sa propre fonction de paiement."],
  [/reserved for the small treasury/i, "Le décaissement d'avance est réservé à la petite trésorerie."],
  [/advance disbursement/i, "Action réservée au décaissement d'avance de la petite trésorerie."],
  [/only the (requester|initiator|beneficiary)/i, "Action réservée à la personne concernée par cette opération."],
  [/only a shareholder/i, "Seul un actionnaire peut effectuer cette opération."],
  [/accept only the two shareholders/i, "Les apports en capital n'acceptent que les deux actionnaires."],
  [/a cancelled transfer cannot be confirmed/i, "Un transfert annulé ne peut pas être confirmé."],
  [/only a pending transfer can be cancelled/i, "Seul un transfert en attente peut être annulé."],
  [/exceed the (loan principal|outstanding (receivable|liability))/i,
    "Le montant dépasse le solde restant dû."],
  [/append-only|is immutable|read-only/i, "Cette donnée est en lecture seule et ne peut pas être modifiée."],
  [/opening balance cannot be changed/i, "Le solde d'ouverture ne peut pas être modifié après le premier mouvement."],
  [/account type cannot be changed|currency cannot be changed/i, "Le type ou la devise du compte ne peut pas être modifié après utilisation."],
  [/used treasury account cannot be deleted/i, "Un compte de trésorerie utilisé ne peut pas être supprimé."],
  [/due date is required/i, "Une date d'échéance est obligatoire pour une échéance planifiée."],
  [/authentication required/i, "Authentification requise."],
];

// SQLSTATE fallbacks.
const SQLSTATE: Record<string, string> = {
  "28000": "Authentification requise.",
  "42501": "Vous n'êtes pas autorisé à effectuer cette action.",
  "23505": "Opération en double détectée.",
  "23503": "Élément introuvable ou référence invalide.",
  "23502": "Un champ obligatoire est manquant.",
  "23514": "Opération refusée par une règle de gestion.",
  "23000": "Cette donnée est protégée et ne peut pas être modifiée.",
  "22P02": "Donnée invalide.",
};

const HTTP: Record<string, number> = { "28000": 401, "42501": 403, "23503": 404 };

export function toAppError(err: unknown): AppError {
  if (err instanceof AppError) return err;
  const pg = (err ?? {}) as PgError;
  const msg = pg.message ?? "";
  for (const [re, fr] of FRAGMENTS) {
    if (re.test(msg)) {
      const code = pg.code ?? "business";
      return new AppError(fr, code, HTTP[code] ?? 400, err);
    }
  }
  if (pg.code && SQLSTATE[pg.code]) {
    return new AppError(SQLSTATE[pg.code]!, pg.code, HTTP[pg.code] ?? 400, err);
  }
  return new AppError("Une erreur inattendue s'est produite.", pg.code ?? "unknown", 500, err);
}
