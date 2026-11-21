import { useState } from "react";
import {
  useAccount,
  useChainId,
  useConnect,
  useDisconnect,
  usePublicClient,
  useReadContract,
  useSwitchChain,
  useWriteContract,
} from "wagmi";
import { erc20Abi, formatUnits, isAddress, keccak256, parseUnits, stringToHex, zeroAddress, type Address } from "viem";
import { prooflockAbi } from "./abi";
import { deployments } from "./config";

const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
const STATUSES = ["None", "Funded", "Delivered", "Disputed", "Released", "Refunded", "Resolved"] as const;

function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const [status, setStatus] = useState("");
  const run = async (label: string, fn: () => Promise<`0x${string}`>) => {
    try {
      setStatus(`${label}: confirm in wallet…`);
      const hash = await fn();
      setStatus(`${label}: pending ${short(hash)}`);
      await client!.waitForTransactionReceipt({ hash });
      setStatus(`${label}: confirmed ✓`);
      return true;
    } catch (e) {
      setStatus(`${label}: ${(e as Error).message.split("\n")[0]}`);
      return false;
    }
  };
  return { writeContractAsync, status, run };
}

export default function App() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { connect, connectors } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain, chains } = useSwitchChain();
  const dep = deployments[chainId] ?? {};
  const [jobId, setJobId] = useState("");
  const deployed = Boolean(dep.prooflock);

  return (
    <div className="wrap">
      <h1>Prooflock</h1>
      <div className="muted">
        Permissionless USDC escrow for one agent job. Fund, deliver a hash, then accept, auto-release, refund or
        arbitrate. Prototype — not audited. Ethereum, Base and local anvil.
      </div>

      <div className="card">
        <h2>Wallet</h2>
        {!isConnected ? (
          <div className="row">
            {connectors.map((c) => (
              <button key={c.uid} onClick={() => connect({ connector: c })}>
                Connect {c.name}
              </button>
            ))}
          </div>
        ) : (
          <div className="row">
            <span>
              Connected <code>{address}</code>
            </span>
            <button className="ghost" onClick={() => disconnect()}>
              Disconnect
            </button>
          </div>
        )}
        <div className="row">
          {chains.map((c) => (
            <button key={c.id} className={c.id === chainId ? "" : "ghost"} onClick={() => switchChain({ chainId: c.id })}>
              {c.name}
            </button>
          ))}
        </div>
        {!deployments[chainId] && <div className="warn">Unsupported chain: use Ethereum, Base or local anvil.</div>}
        {deployments[chainId] && !dep.prooflock && (
          <div className="warn">
            <strong>Not deployed yet</strong> on this chain — the Prooflock address is empty. Create, deliver, accept,
            dispute and refund stay disabled until you deploy (<code>make deploy-mainnet</code> or{" "}
            <code>make deploy-base</code>), which writes the address into <code>web/src/deployments.json</code>.
          </div>
        )}
        {deployments[chainId]?.live && dep.prooflock && (
          <div className="warn">
            Live chain with real funds. This contract is NOT audited — only deposit amounts you can afford to lose.
          </div>
        )}
      </div>

      {isConnected && address && deployed && dep.prooflock && dep.usdc && (
        <>
          <CreateJob
            escrow={dep.prooflock}
            usdc={dep.usdc}
            onCreated={(id) => setJobId(id)}
          />
          <div className="card">
            <h2>Look up a job</h2>
            <div className="row">
              <label>
                Job id
                <input value={jobId} onChange={(e) => setJobId(e.target.value)} placeholder="1" />
              </label>
            </div>
          </div>
          {jobId && /^\d+$/.test(jobId) && Number(jobId) > 0 && (
            <JobPanel escrow={dep.prooflock} usdc={dep.usdc} jobId={BigInt(jobId)} account={address} />
          )}
        </>
      )}
    </div>
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
  const { writeContractAsync, status, run } = useTx();
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
    if (!isAddress(provider)) return;
    const amt = parseUnits(amount || "0", 6);
    const bondAmt = parseUnits(bond || "0", 6);
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
            clientAgentId: BigInt(clientAgentId || "0"),
            providerAgentId: BigInt(providerAgentId || "0"),
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
      <h2>Create job</h2>
      <div className="row">
        <label>
          Provider
          <input value={provider} onChange={(e) => setProvider(e.target.value)} placeholder="0x…" />
        </label>
        <label>
          Arbiter (optional)
          <input value={arbiter} onChange={(e) => setArbiter(e.target.value)} placeholder="0x… or leave empty" />
        </label>
      </div>
      <div className="row">
        <label>
          Amount (USDC)
          <input value={amount} onChange={(e) => setAmount(e.target.value)} />
        </label>
        <label>
          Provider bond (USDC)
          <input value={bond} onChange={(e) => setBond(e.target.value)} />
        </label>
        <label>
          Deadline (days)
          <input value={deadlineDays} onChange={(e) => setDeadlineDays(e.target.value)} />
        </label>
        <label>
          Review window (days)
          <input value={reviewDays} onChange={(e) => setReviewDays(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <label>
          Metadata URI
          <input value={metadata} onChange={(e) => setMetadata(e.target.value)} placeholder="ipfs://… (optional)" />
        </label>
        <label>
          Client agent id
          <input value={clientAgentId} onChange={(e) => setClientAgentId(e.target.value)} />
        </label>
        <label>
          Provider agent id
          <input value={providerAgentId} onChange={(e) => setProviderAgentId(e.target.value)} />
        </label>
      </div>
      <div className="row">
        <button onClick={submit} disabled={!isAddress(provider)}>
          Approve & create
        </button>
      </div>
      {status && <div className="muted">{status}</div>}
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
  const { writeContractAsync, status, run } = useTx();
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

  if (!data) return <div className="card">Loading job {jobId.toString()}…</div>;
  const job = data;
  if (job.status === 0) {
    return (
      <div className="card">
        <h2>Job {jobId.toString()}</h2>
        <div className="muted">No job with this id.</div>
      </div>
    );
  }
  const statusName = STATUSES[job.status] ?? String(job.status);
  const isClient = job.client.toLowerCase() === account.toLowerCase();
  const isProvider = job.provider.toLowerCase() === account.toLowerCase();
  const isArbiter = job.arbiter.toLowerCase() === account.toLowerCase();
  const when = (n: bigint) => (n === 0n ? "—" : new Date(Number(n) * 1000).toLocaleString());

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
        Job {jobId.toString()} — <span className="ok">{statusName}</span>
      </h2>
      <dl className="dl">
        <dt>Client</dt>
        <dd>
          <code>{job.client}</code>
        </dd>
        <dt>Provider</dt>
        <dd>
          <code>{job.provider}</code>
        </dd>
        <dt>Arbiter</dt>
        <dd>
          <code>{job.arbiter === zeroAddress ? "none" : job.arbiter}</code>
        </dd>
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
          {job.deliverableHash === "0x".padEnd(66, "0") ? "—" : <code>{job.deliverableHash}</code>}
          {job.deliverableURI ? ` ${job.deliverableURI}` : ""}
        </dd>
        <dt>Metadata</dt>
        <dd>{job.metadataURI || "—"}</dd>
      </dl>

      {job.status === 1 && isProvider && job.bondRequired > 0n && job.bondDeposited === 0n && (
        <div className="row">
          <button
            onClick={async () => {
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
            }}
          >
            Post bond
          </button>
        </div>
      )}

      {job.status === 1 && isProvider && (
        <div className="row">
          <label>
            Deliverable (hash or text)
            <input value={hashInput} onChange={(e) => setHashInput(e.target.value)} placeholder="0x… or text to hash" />
          </label>
          <label>
            URI (optional)
            <input value={uri} onChange={(e) => setUri(e.target.value)} placeholder="ipfs://…" />
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
        </div>
      )}

      {job.status === 2 && (
        <div className="row">
          <button
            className="ghost"
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
            Auto-release (after review window)
          </button>
        </div>
      )}

      {job.status === 1 && (
        <div className="row">
          <button
            className="ghost"
            onClick={() =>
              after("Refund", () =>
                writeContractAsync({ address: escrow, abi: prooflockAbi, functionName: "refund", args: [jobId] }),
              )
            }
          >
            Refund (after missed deadline)
          </button>
        </div>
      )}

      {job.status === 3 && isArbiter && (
        <div className="row">
          <label>
            Provider payout (USDC)
            <input value={payout} onChange={(e) => setPayout(e.target.value)} placeholder={formatUnits(job.amount, 6)} />
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
            Resolve
          </button>
        </div>
      )}

      {status && <div className="muted">{status}</div>}
    </div>
  );
}
