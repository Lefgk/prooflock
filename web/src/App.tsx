import { useState } from "react";
import { useAccount, useChainId, usePublicClient, useReadContract } from "wagmi";
import { erc20Abi, formatUnits, isAddress, keccak256, parseUnits, stringToHex, zeroAddress, type Address } from "viem";
import { prooflockAbi } from "./abi";
import { deployments } from "./config";
import { Addr, Empty, Hint, Loading, Shell, short, useTx } from "./ui";

const STATUSES = ["None", "Funded", "Delivered", "Disputed", "Released", "Refunded", "Resolved"] as const;

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const dep = deployments[chainId] ?? {};
  const [jobId, setJobId] = useState("");
  const validJobId = /^\d+$/.test(jobId) && Number(jobId) > 0;

  return (
    <Shell
      title="Prooflock"
      tagline="USDC escrow for one job between a client and an AI agent or other provider. The client locks the payment; the provider delivers a proof hash before the deadline; the client accepts, or the payment releases by itself after the review window. Missed deadlines refund the client."
      steps={[
        "Client creates a job: USDC is locked in the contract for one provider.",
        "Provider posts the bond (if required) and submits a deliverable hash before the deadline.",
        "Client accepts or disputes within the review window; no answer releases to the provider.",
        "No delivery by the deadline: anyone can refund the client.",
      ]}
      contractLabel="Prooflock"
      contractOf={(id) => deployments[id]?.prooflock}
      refs={[{ label: "USDC", address: dep.usdc }]}
      risk={
        <>
          <strong>Real funds.</strong> This contract is not audited. Escrowed USDC is paid to the provider if you accept
          or let the review window pass, and a disputed job is decided by the arbiter named at creation. Only escrow
          amounts you can afford to lose.
        </>
      }
    >
      {!isConnected && <Empty>Connect a wallet to create a job or act on one you are part of.</Empty>}

      {isConnected && address && dep.prooflock && dep.usdc && (
        <>
          <CreateJob escrow={dep.prooflock} usdc={dep.usdc} onCreated={(id) => setJobId(id)} />
          <div className="card">
            <h2>2. Look up a job</h2>
            <div className="row">
              <label>
                Job id
                <input value={jobId} inputMode="numeric" onChange={(e) => setJobId(e.target.value.trim())} placeholder="1" />
              </label>
            </div>
            {jobId && !validJobId && <div className="bad muted">A job id is a whole number starting at 1.</div>}
            {!jobId && <p className="muted">Enter the id of a job you created or were named in. A new job is selected automatically.</p>}
          </div>
          {validJobId && <JobPanel escrow={dep.prooflock} usdc={dep.usdc} jobId={BigInt(jobId)} account={address} />}
        </>
      )}
    </Shell>
  );
}

function CreateJob({
  escrow,
  usdc,
  onCreated,
}: {
  escrow: Address;
  usdc: Address;
  onCreated: (id: string) => void;
}) {
  const { address } = useAccount();
  const { writeContractAsync, status, run, safe, fail } = useTx();
  const client = usePublicClient();
  const [provider, setProvider] = useState("");
  const [arbiter, setArbiter] = useState("");
  const [amount, setAmount] = useState("100");
  const [bond, setBond] = useState("0");
  const [deadlineDays, setDeadlineDays] = useState("7");
  const [reviewDays, setReviewDays] = useState("3");
  const [metadata, setMetadata] = useState("");
  const [clientAgentId, setClientAgentId] = useState("0");
  const [providerAgentId, setProviderAgentId] = useState("0");

  const { data: allowance, refetch } = useReadContract({
    address: usdc,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, escrow] : undefined,
    query: { enabled: Boolean(address) },
  });

  const submit = async () => {
    if (!isAddress(provider)) return fail("Provider must be a valid address (0x followed by 40 hex characters).");
    if (arbiter && !isAddress(arbiter)) return fail("Arbiter must be a valid address, or left empty.");
    const amt = parseUnits(amount || "0", 6);
    if (amt === 0n) return fail("Amount must be greater than 0.");
    const bondAmt = parseUnits(bond || "0", 6);
    const clientId = BigInt(clientAgentId || "0");
    const providerId = BigInt(providerAgentId || "0");
    const needed = amt;
    if ((allowance ?? 0n) < needed) {
      const ok = await run("Approve USDC", () =>
        writeContractAsync({ address: usdc, abi: erc20Abi, functionName: "approve", args: [escrow, needed] }),
      );
      if (!ok) return;
      await refetch();
    }
    const now = BigInt(Math.floor(Date.now() / 1000));
    const deadline = now + BigInt(Math.max(1, Number(deadlineDays) || 7) * 86400);
    const reviewWindow = BigInt(Math.max(1, Number(reviewDays) || 3) * 86400);
    const ok = await run("Create job", () =>
      writeContractAsync({
        address: escrow,
        abi: prooflockAbi,
        functionName: "createJob",
        args: [
          {
            provider: provider as Address,
            arbiter: isAddress(arbiter) ? (arbiter as Address) : zeroAddress,
            amount: amt,
            deadline,
            reviewWindow,
            bondRequired: bondAmt,
            clientAgentId: clientId,
            providerAgentId: providerId,
            metadataURI: metadata,
          },
        ],
      }),
    );
    if (!ok || !client) return;
    const id = await client.readContract({ address: escrow, abi: prooflockAbi, functionName: "nextJobId" });
    onCreated(String(id - 1n));
  };

  return (
    <div className="card">
      <h2>1. Create a job (client)</h2>
      <p className="muted">You are the client. The provider is the address that will be paid for the work.</p>
      <div className="row">
        <label>
          Provider address
          <input value={provider} spellCheck={false} onChange={(e) => setProvider(e.target.value.trim())} placeholder="0x…" />
        </label>
        <label>
          Arbiter (optional, decides disputes)
          <input value={arbiter} spellCheck={false} onChange={(e) => setArbiter(e.target.value.trim())} placeholder="0x… or leave empty" />
        </label>
      </div>
      <div className="row">
        <label>
          Payment (USDC)
          <input value={amount} inputMode="decimal" onChange={(e) => setAmount(e.target.value)} />
        </label>
        <label>
          Provider bond (USDC, 0 = none)
          <input value={bond} inputMode="decimal" onChange={(e) => setBond(e.target.value)} />
        </label>
        <label>
          Delivery deadline (days)
          <input value={deadlineDays} inputMode="decimal" onChange={(e) => setDeadlineDays(e.target.value)} />
        </label>
        <label>
          Review window (days)
          <input value={reviewDays} inputMode="decimal" onChange={(e) => setReviewDays(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <label>
          Job description URI (optional)
          <input value={metadata} spellCheck={false} onChange={(e) => setMetadata(e.target.value)} placeholder="ipfs://…" />
        </label>
        <label>
          Client agent id (ERC-8004, 0 = none)
          <input value={clientAgentId} inputMode="numeric" onChange={(e) => setClientAgentId(e.target.value)} />
        </label>
        <label>
          Provider agent id (ERC-8004, 0 = none)
          <input value={providerAgentId} inputMode="numeric" onChange={(e) => setProviderAgentId(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <button onClick={safe(submit)} disabled={!isAddress(provider)}>
          Approve + create job
        </button>
      </div>
      {!arbiter && (
        <div className="info">No arbiter: you will not be able to dispute a delivery. You can only accept it or let it auto-release.</div>
      )}
      <Hint>
        Up to two wallet prompts: an approval for exactly the payment (skipped if already approved), then “create
        job”, which moves the payment from your wallet into the Prooflock contract. It is paid to the provider when
        you accept or the review window passes, and refunded to you if nothing is delivered by the deadline.
      </Hint>
      {status}
    </div>
  );
}

function JobPanel({
  escrow,
  usdc,
  jobId,
  account,
}: {
  escrow: Address;
  usdc: Address;
  jobId: bigint;
  account: Address;
}) {
  const { writeContractAsync, status, run, safe } = useTx();
  const { data, refetch } = useReadContract({
    address: escrow,
    abi: prooflockAbi,
    functionName: "jobs",
    args: [jobId],
  });
  const { data: allowance, refetch: refetchAllow } = useReadContract({
    address: usdc,
    abi: erc20Abi,
    functionName: "allowance",
    args: [account, escrow],
  });
  const [uri, setUri] = useState("");
  const [hashInput, setHashInput] = useState("");
  const [payout, setPayout] = useState("");
  const [slash, setSlash] = useState(false);

  if (!data)
    return (
      <div className="card">
        <h2>3. Job {jobId.toString()}</h2>
        <Loading />
      </div>
    );
  const job = data;
  if (job.status === 0) {
    return (
      <div className="card">
        <h2>3. Job {jobId.toString()}</h2>
        <Empty>No job with this id on this network.</Empty>
      </div>
    );
  }
  const statusName = STATUSES[job.status] ?? String(job.status);
  const isClient = job.client.toLowerCase() === account.toLowerCase();
  const isProvider = job.provider.toLowerCase() === account.toLowerCase();
  const isArbiter = job.arbiter.toLowerCase() === account.toLowerCase();
  const when = (n: bigint) => (n === 0n ? "—" : new Date(Number(n) * 1000).toLocaleString());

  const now = BigInt(Math.floor(Date.now() / 1000));
  const settled = job.status >= 4;
  const role = [isClient && "client", isProvider && "provider", isArbiter && "arbiter"].filter(Boolean).join(" and ");

  const after = async (label: string, fn: () => Promise<`0x${string}`>) => {
    const ok = await run(label, fn);
    if (ok) await refetch();
  };

  const deliverHash = (): `0x${string}` => {
    const t = hashInput.trim();
    if (/^0x[0-9a-fA-F]{64}$/.test(t)) return t as `0x${string}`;
    return keccak256(stringToHex(t || uri || `job-${jobId}`));
  };

  return (
    <div className="card">
      <h2>
        3. Job {jobId.toString()} · <span className={job.status === 3 ? "bad" : "ok"}>{statusName}</span>
      </h2>
      <p className="muted">
        {role ? `You are the ${role} of this job.` : "You are not a party to this job; only the open-to-anyone actions will work."}
      </p>
      <dl className="dl">
        <dt>Client</dt>
        <dd>
          <Addr value={job.client} />
        </dd>
        <dt>Provider</dt>
        <dd>
          <Addr value={job.provider} />
        </dd>
        <dt>Arbiter</dt>
        <dd>{job.arbiter === zeroAddress ? "none (no disputes)" : <Addr value={job.arbiter} />}</dd>
        <dt>Amount</dt>
        <dd>{formatUnits(job.amount, 6)} USDC</dd>
        <dt>Bond required / posted</dt>
        <dd>
          {formatUnits(job.bondRequired, 6)} / {formatUnits(job.bondDeposited, 6)} USDC
        </dd>
        <dt>Deadline</dt>
        <dd>{when(job.deadline)}</dd>
        <dt>Review deadline</dt>
        <dd>{when(job.reviewDeadline)}</dd>
        <dt>Fee (snapshotted)</dt>
        <dd>{job.feeBps / 100}%</dd>
        <dt>Deliverable</dt>
        <dd>
          {job.deliverableHash === "0x".padEnd(66, "0") ? "—" : <code title="Deliverable hash">{job.deliverableHash}</code>}
          {job.deliverableURI ? ` ${job.deliverableURI}` : ""}
        </dd>
        <dt>Metadata</dt>
        <dd>{job.metadataURI || "—"}</dd>
      </dl>

      {job.status === 1 && isProvider && job.bondRequired > 0n && job.bondDeposited === 0n && (
        <div className="row">
          <button
            onClick={safe(async () => {
              if ((allowance ?? 0n) < job.bondRequired) {
                const ok = await run("Approve bond", () =>
                  writeContractAsync({
                    address: usdc,
                    abi: erc20Abi,
                    functionName: "approve",
                    args: [escrow, job.bondRequired],
                  }),
                );
                if (!ok) return;
                await refetchAllow();
              }
              await after("Post bond", () =>
                writeContractAsync({ address: escrow, abi: prooflockAbi, functionName: "postBond", args: [jobId] }),
              );
            })}
          >
            Approve + post bond
          </button>
          <Hint>
            Moves the {formatUnits(job.bondRequired, 6)} USDC bond from your wallet into the contract. It is required
            before you can deliver, comes back when the job settles, and can be given to the client by the arbiter in
            a dispute.
          </Hint>
        </div>
      )}

      {job.status === 1 && isProvider && (
        <div className="row">
          <label>
            Deliverable (hash or text)
            <input value={hashInput} spellCheck={false} onChange={(e) => setHashInput(e.target.value)} placeholder="0x… or text to hash" />
          </label>
          <label>
            URI (optional)
            <input value={uri} spellCheck={false} onChange={(e) => setUri(e.target.value)} placeholder="ipfs://…" />
          </label>
          <button
            onClick={() =>
              after("Deliver", () =>
                writeContractAsync({
                  address: escrow,
                  abi: prooflockAbi,
                  functionName: "deliver",
                  args: [jobId, deliverHash(), uri],
                }),
              )
            }
          >
            Submit deliverable
          </button>
          <Hint>
            Records the hash of your work on-chain and starts the client's review window. A 0x…64-hex value is used
            as the hash as is; any other text is hashed first. Must be sent before the deadline. No funds move yet.
          </Hint>
        </div>
      )}

      {job.status === 2 && isClient && (
        <div className="row">
          <button
            onClick={() =>
              after("Accept", () =>
                writeContractAsync({ address: escrow, abi: prooflockAbi, functionName: "accept", args: [jobId] }),
              )
            }
          >
            Accept & release
          </button>
          {job.arbiter !== zeroAddress && (
            <button
              className="danger"
              onClick={() =>
                after("Dispute", () =>
                  writeContractAsync({ address: escrow, abi: prooflockAbi, functionName: "dispute", args: [jobId] }),
                )
              }
            >
              Dispute
            </button>
          )}
          <Hint tone="danger">
            Accept is final: it pays {formatUnits(job.amount, 6)} USDC (minus the {job.feeBps / 100}% fee) to the
            provider right away.
            {job.arbiter !== zeroAddress
              ? " Dispute hands the decision to the arbiter, who splits the payment; it must be sent before the review deadline."
              : " This job has no arbiter, so it cannot be disputed."}
          </Hint>
        </div>
      )}

      {job.status === 3 && (
        <div className="row">
          <button
            className="ghost"
            onClick={() =>
              after("Settle stale dispute", () =>
                writeContractAsync({
                  address: escrow,
                  abi: prooflockAbi,
                  functionName: "resolveStaleDispute",
                  args: [jobId],
                }),
              )
            }
          >
            Settle 50/50 (stale dispute)
          </button>
          <Hint>
            Open to anyone, but only once the arbiter has left the dispute undecided past the timeout after the review
            deadline. Splits the payment half to the provider, half to the client, and returns the bond to the
            provider.
          </Hint>
        </div>
      )}

      {job.status === 2 && (
        <div className="row">
          <button
            className="ghost"
            disabled={now < job.reviewDeadline}
            onClick={() =>
              after("Auto-release", () =>
                writeContractAsync({
                  address: escrow,
                  abi: prooflockAbi,
                  functionName: "autoRelease",
                  args: [jobId],
                }),
              )
            }
          >
            Auto-release to provider
          </button>
          <Hint>
            Open to anyone once the review window has passed without a dispute ({when(job.reviewDeadline)}). Pays the
            provider the full amount minus the fee.
          </Hint>
        </div>
      )}

      {job.status === 1 && (
        <div className="row">
          <button
            className="ghost"
            disabled={now < job.deadline}
            onClick={() =>
              after("Refund", () =>
                writeContractAsync({ address: escrow, abi: prooflockAbi, functionName: "refund", args: [jobId] }),
              )
            }
          >
            Refund client
          </button>
          <Hint>
            Open to anyone once the deadline has passed with nothing delivered ({when(job.deadline)}). Returns the
            full payment to the client and any posted bond to the provider.
          </Hint>
        </div>
      )}

      {job.status === 3 && isArbiter && (
        <div className="row">
          <label>
            Provider payout (USDC)
            <input value={payout} inputMode="decimal" onChange={(e) => setPayout(e.target.value)} placeholder={formatUnits(job.amount, 6)} />
          </label>
          <label>
            Slash bond to client
            <select value={slash ? "yes" : "no"} onChange={(e) => setSlash(e.target.value === "yes")}>
              <option value="no">No — return bond</option>
              <option value="yes">Yes — slash to client</option>
            </select>
          </label>
          <button
            onClick={() =>
              after("Resolve", () =>
                writeContractAsync({
                  address: escrow,
                  abi: prooflockAbi,
                  functionName: "resolve",
                  args: [jobId, parseUnits(payout || "0", 6), slash],
                }),
              )
            }
          >
            Resolve dispute
          </button>
          <Hint tone="danger">
            Final. Pays the provider the amount you enter (0 to {formatUnits(job.amount, 6)} USDC, minus the fee) and
            returns the rest to the client. Slashing sends the provider's bond to the client instead of back to the
            provider.
          </Hint>
        </div>
      )}
      {job.status === 3 && !isArbiter && (
        <div className="info">Disputed: waiting for the arbiter (<Addr value={job.arbiter} copy={false} />) to decide.</div>
      )}
      {settled && <div className="info">This job is settled. No further actions are possible.</div>}

      {status}
    </div>
  );
}
