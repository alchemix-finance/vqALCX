# Late workspace context

`AGENTS.md` and these untracked tests appeared during the audit, after the clean baseline and system campaign had run:

- `test/audit/reaudit/StakingReaudit.t.sol`
- `test/audit/reaudit/VaultReaudit.t.sol`

They were not part of the recorded baseline or accepted system harness. Their creation is not attributed here, and their results are not counted in this pass. They were left intact. Hashes at observation time are in `evidence/late-context-hashes.json`. The three first-party contract hashes still match the frozen target.

The new `AGENTS.md` was read before delivery. It confirms that requests escrow tokens at request time and explicitly describes the aggregate `max*` values and single-request claims as non-standard behavior. Accordingly, the report treats those two maxima observations as compatibility notes rather than unintended code behavior. The conflict with the architecture's ERC-4626 promise still needs a standards/integration decision.

AGENTS.md also names `mode=blockstamp` as the current staking clock descriptor. That instruction does not make the value comply with the published timestamp-clock interface. The report recommends reconciling the requirement and code together; no unilateral production change was made.

Its simplified profit expression, vault balance minus supply, does not deduct still-owed unminted deposit principal. The audit's complete liability model retains those obligations. No surplus-harvest function or external treasury deployment was introduced or assumed.

The audit files remain working evidence. Neither AGENTS.md nor previous audit notes were treated as proof that tests passed or that a deployment was safe. The automatic reviewer-filter message originated in the review service; AGENTS.md does not contain such a project-specific security finding.
