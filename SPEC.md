# Prooflock — spec (prototype, 22 Nov 2026)

Source: overnight agent-payments research, idea 1. Closest rivals (Virtuals ACP / ERC-8183, Armalo, Kleros, Nevermined) are platform- or evaluator-heavy, and none ships a tiny permissionless primitive on both Ethereum mainnet and Base.

**Problem.** Paying another agent still means prepaid trust or joining a platform.

**Users.** Builders hiring an agent for one deliverable, and agents who want the budget locked first.

**Scope (v0, Ethereum mainnet and Base, after an audit and Lef's OK).** One contract. The client funds a USDC job naming a provider, a deadline, an optional arbiter and an optional provider bond. Optional ERC-8004 agent IDs are metadata only. The provider posts the bond (if required), then a deliverable hash/URI before the deadline. Funds release on client accept, auto-release after a review window if the client is silent, refund on a missed deadline (bond returned), or an arbiter split with optional bond slash to the client. Protocol fee defaults to 0, owner-settable, hard-capped at 5%, snapshotted at creation, taken only from the provider's payout. Job page: create, deliver, accept, dispute, refund. Out: milestones, other tokens, other chains, a built-in court.

**Choices for Lef to review.** (1) No client cancel after funding; missed-deadline refund is the escape hatch. (2) Jobs without an arbiter cannot be disputed; they auto-release after review. (3) No arbiter timeout in v1. (4) Bond is slashed only when the arbiter sets `slashBond`; a no-show returns it. (5) Fee recipient and owner start as the deployer (Ownable2Step). (6) Review window is per-job, 1 hour–30 days; deadline 1 hour–180 days out.

**Edge.** Tiny, permissionless, USDC-only, on Ethereum and Base, no platform or jury.

**Open questions.** Audit before mainnet, keeping the fee at 0, an arbiter timeout, and the owner / fee-recipient wallet (EOA or Safe).
