import "server-only";
import { runUser, one } from "@/services/_run";
import { historyFilterSchema, exportSchema } from "@/lib/schemas";
import type { z } from "zod";
import type { TransactionHistoryRow, AuditLog, UUID } from "@/lib/types";

/** Global transaction history with combined filters (§11.1), RLS-scoped. */
export async function getTransactionHistory(
  actor: UUID,
  filter: z.input<typeof historyFilterSchema>,
): Promise<TransactionHistoryRow[]> {
  const f = historyFilterSchema.parse(filter);
  const refPattern = f.reference ? `%${f.reference}%` : null;
  const byPattern = f.posted_by ? `%${f.posted_by}%` : null;
  return runUser(actor, (tx) => tx<TransactionHistoryRow[]>`
    select * from v_transaction_history
    where (${f.date_from ?? null}::timestamptz is null or posted_at >= ${f.date_from ?? null})
      and (${f.date_to ?? null}::timestamptz is null or posted_at <= ${f.date_to ?? null})
      and (${f.treasury ?? null}::text is null or treasury = ${f.treasury ?? null})
      and (${f.movement_type ?? null}::text is null or movement_type = ${f.movement_type ?? null})
      and (${f.amount_min ?? null}::numeric is null or amount >= ${f.amount_min ?? null})
      and (${f.amount_max ?? null}::numeric is null or amount <= ${f.amount_max ?? null})
      and (${f.reference ?? null}::text is null or reference ilike ${refPattern})
      and (${f.source_type ?? null}::text is null or source_type = ${f.source_type ?? null})
      and (${f.posted_by ?? null}::text is null or posted_by ilike ${byPattern})
    order by posted_at desc
    limit ${f.limit} offset ${f.offset}
  `.then((r) => [...r]));
}

/** Log an export to the audit trail (§11.3). Returns the audit row. */
export async function recordExport(actor: UUID, input: z.input<typeof exportSchema>): Promise<AuditLog> {
  const v = exportSchema.parse(input);
  return runUser(actor, async (tx) => one(await tx<AuditLog[]>`
    select * from record_export(${v.report_type}, ${JSON.stringify(v.filters)}::jsonb)
  `));
}
