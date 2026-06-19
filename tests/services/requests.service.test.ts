import { describe, it, expect } from "vitest";
import * as requests from "@/services/requests.service";
import * as treasury from "@/services/treasury.service";
import { USERS } from "../setup/testdb";

async function smallBalance(): Promise<number> {
  const rows = await treasury.getBalances(USERS.accountant);
  return rows.find((r) => r.code === "SMALL")!.balance;
}

describe("requests.service", () => {
  it("runs the full approve -> approve -> pay flow and debits the treasury once", async () => {
    const before = await smallBalance();
    const req = await requests.createRequest(USERS.ops, {
      amount: 50_000, beneficiary_type: "external", beneficiary_name: "Total",
      purpose: "Carburant", category: "operations", proposed_treasury: "small_treasury",
    });
    const detail = await requests.getRequestDetail(USERS.ops, req.id);
    const versionId = detail!.versions[0]!.id;

    await requests.recordFirstValidation(USERS.validator, { version_id: versionId, decision: "approved" });
    await requests.recordFinalValidation(USERS.super, { version_id: versionId, decision: "approved" });
    const payment = await requests.payRequest(USERS.cashier, { request_id: req.id });

    expect(payment.status).toBe("completed");
    expect(payment.amount).toBe(50_000); // exact approved amount — no partial possible
    expect(await smallBalance()).toBe(before - 50_000);
  });

  it("blocks an unauthorized role with a French message", async () => {
    const req = await requests.createRequest(USERS.ops, {
      amount: 1_000, beneficiary_type: "external", beneficiary_name: "X",
      purpose: "Test", category: "operations", proposed_treasury: "small_treasury",
    });
    const detail = await requests.getRequestDetail(USERS.ops, req.id);
    const versionId = detail!.versions[0]!.id;
    // Operations Director cannot give first-level approval.
    await expect(requests.recordFirstValidation(USERS.ops, { version_id: versionId, decision: "approved" }))
      .rejects.toMatchObject({ message: /autoris/i });
  });

  it("refuses payment when the balance is insufficient (nothing is paid)", async () => {
    const req = await requests.createRequest(USERS.ops, {
      amount: 9_000_000, beneficiary_type: "external", beneficiary_name: "Gros fournisseur",
      purpose: "Achat", category: "operations", proposed_treasury: "large_treasury",
    });
    const detail = await requests.getRequestDetail(USERS.ops, req.id);
    const versionId = detail!.versions[0]!.id;
    await requests.recordFirstValidation(USERS.validator, { version_id: versionId, decision: "approved" });
    await requests.recordFinalValidation(USERS.super, { version_id: versionId, decision: "approved" });

    await expect(requests.payRequest(USERS.accountant, { request_id: req.id }))
      .rejects.toMatchObject({ message: /Solde insuffisant/i });
  });

  it("requires a comment to refuse (Zod) ", async () => {
    const req = await requests.createRequest(USERS.ops, {
      amount: 2_000, beneficiary_type: "external", beneficiary_name: "Y",
      purpose: "Test", category: "operations", proposed_treasury: "small_treasury",
    });
    const detail = await requests.getRequestDetail(USERS.ops, req.id);
    const versionId = detail!.versions[0]!.id;
    await expect(requests.recordFirstValidation(USERS.validator, { version_id: versionId, decision: "not_approved" }))
      .rejects.toThrow(); // Zod: comment mandatory
  });
});
