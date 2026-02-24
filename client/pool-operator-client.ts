/**
 * BOTCOIN Mining Pool — Operator Client
 *
 * Drives the mining loop against the real coordinator at agentmoney.net.
 * Uses Bankr API for wallet resolution, signing, and on-chain tx submission.
 *
 * CRITICAL DIFFERENCE vs solo mining:
 *   Solo miner submits coordinator's transaction directly to the mining contract.
 *   Pool operator wraps coordinator calldata through the pool contract's
 *   submitReceiptToMining() and claimEpochReward() functions, so the mining
 *   contract sees msg.sender == pool (not the operator EOA).
 *
 * Architecture:
 *   Coordinator (off-chain)  →  challenge + pre-encoded calldata
 *                                      ↓
 *   This client  →  wraps calldata  →  pool.submitReceiptToMining(calldata)
 *                                      pool.claimEpochReward(epochId, calldata)
 *                                      ↓
 *   Bankr API  →  signs & submits tx targeting the pool contract
 */

import { ethers } from 'ethers';

// ─── Configuration ──────────────────────────────────────────────────────────

export interface PoolOperatorConfig {
  /** Bankr API key (write access + agent API enabled, read-only OFF) */
  bankrApiKey: string;

  /** Coordinator base URL */
  coordinatorUrl?: string;

  /** Pool contract address on Base */
  poolContractAddress: string;

  /** Chain ID (default: 8453 = Base mainnet) */
  chainId?: number;

  /** LLM solve function: receives challenge, returns artifact string */
  solveFn: (challenge: ChallengePackage) => Promise<string>;

  /** Max consecutive solve failures before stopping */
  maxFailures?: number;

  /** Delay between mining loops (ms) */
  loopDelayMs?: number;
}

// ─── Types ──────────────────────────────────────────────────────────────────

export interface ChallengePackage {
  challengeId: string;
  epochId: number;
  doc: string;
  questions: string[];
  constraints: string[];
  companies: string[];
  creditsPerSolve: number;
  solveInstructions?: string;
}

export interface SubmitResult {
  pass: boolean;
  receipt?: Record<string, unknown>;
  signature?: string;
  transaction?: TransactionData;
  failedConstraintIndices?: number[];
}

export interface TransactionData {
  to: string;
  chainId: number;
  value: string;
  data: string;
}

export interface EpochInfo {
  epochId: number;
  prevEpochId: number | null;
  nextEpochStartTimestamp: number;
  epochDurationSeconds: number;
}

export interface CreditsInfo {
  miner: string;
  epochs: Record<string, number>;
}

export interface BankrTxResult {
  success: boolean;
  transactionHash?: string;
  status?: string;
  blockNumber?: string;
  gasUsed?: string;
  error?: string;
}

// ─── Pool ABI fragments (for wrapping calldata) ─────────────────────────────

const POOL_ABI = [
  'function submitReceiptToMining(bytes calldata calldata_)',
  'function claimEpochReward(uint256 epochId, bytes calldata claimCalldata)',
];

// ─── Auth Token Manager ─────────────────────────────────────────────────────

class AuthTokenManager {
  private token: string | null = null;
  private expiresAt: number = 0;
  private refreshLock: Promise<string> | null = null;

  constructor(
    private coordinatorUrl: string,
    private minerAddress: string,
    private bankrApiKey: string,
  ) {}

  /** Get a valid auth token, refreshing if expired or near expiry */
  async getToken(): Promise<string> {
    // Jitter: refresh 30-90s before expiry to avoid synchronized refreshes
    const jitter = 30_000 + Math.random() * 60_000;
    if (this.token && Date.now() < this.expiresAt - jitter) {
      return this.token;
    }
    return this.refresh();
  }

  /** Force a token refresh with single-flight dedup */
  async refresh(): Promise<string> {
    // Only one refresh in flight at a time
    if (this.refreshLock) return this.refreshLock;

    this.refreshLock = this._doRefresh();
    try {
      return await this.refreshLock;
    } finally {
      this.refreshLock = null;
    }
  }

  private async _doRefresh(): Promise<string> {
    // Step 1: Get nonce from coordinator
    const nonceRes = await fetchWithRetry(
      `${this.coordinatorUrl}/v1/auth/nonce`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ miner: this.minerAddress }),
      },
    );
    const nonceData = await nonceRes.json();
    const message: string = nonceData.message;
    if (!message) {
      throw new Error(`Auth nonce missing .message: ${JSON.stringify(nonceData)}`);
    }

    // Step 2: Sign via Bankr (personal_sign)
    // The coordinator will call pool.isValidSignature(digest, signature) and the
    // pool verifies the signature came from the operator EOA.
    const signRes = await fetch('https://api.bankr.bot/agent/sign', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': this.bankrApiKey,
      },
      body: JSON.stringify({
        signatureType: 'personal_sign',
        message,
      }),
    });
    if (!signRes.ok) {
      const err = await signRes.text();
      throw new Error(`Bankr sign failed (${signRes.status}): ${err}`);
    }
    const signData = await signRes.json();
    const signature: string = signData.signature;
    if (!signature) {
      throw new Error(`Bankr sign missing .signature: ${JSON.stringify(signData)}`);
    }

    // Step 3: Verify with coordinator → get bearer token
    const verifyRes = await fetchWithRetry(
      `${this.coordinatorUrl}/v1/auth/verify`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          miner: this.minerAddress,
          message,
          signature,
        }),
      },
    );

    if (verifyRes.status === 401) {
      throw new Error('Auth verify returned 401 — signature rejected');
    }
    if (verifyRes.status === 403) {
      throw new Error('INSUFFICIENT_BALANCE');
    }

    const verifyData = await verifyRes.json();
    this.token = verifyData.token;
    if (!this.token) {
      throw new Error(`Auth verify missing .token: ${JSON.stringify(verifyData)}`);
    }

    // Conservative 55-minute lifetime (actual may be ~60m)
    this.expiresAt = Date.now() + 55 * 60 * 1000;
    return this.token;
  }

  /** Mark token as invalid (triggers refresh on next getToken call) */
  invalidate(): void {
    this.expiresAt = 0;
  }
}

// ─── Retry Helper ───────────────────────────────────────────────────────────

const BACKOFF_SCHEDULE = [2000, 4000, 8000, 16000, 30000, 60000];

async function fetchWithRetry(
  url: string,
  init: RequestInit,
  maxRetries = 6,
): Promise<Response> {
  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    const res = await fetch(url, init);
    if (res.ok) return res;

    // Don't retry 4xx (except 429)
    if (res.status >= 400 && res.status < 500 && res.status !== 429) {
      return res; // caller decides
    }

    // Retry on 429 and 5xx
    if (attempt < maxRetries) {
      const backoff = BACKOFF_SCHEDULE[Math.min(attempt, BACKOFF_SCHEDULE.length - 1)];
      const jitter = backoff * Math.random() * 0.25;

      // Respect retryAfterSeconds from response body
      try {
        const body = await res.clone().json();
        if (body.retryAfterSeconds) {
          const serverWait = body.retryAfterSeconds * 1000;
          await sleep(Math.max(serverWait, backoff) + jitter);
          continue;
        }
      } catch {}

      await sleep(backoff + jitter);
    }
  }
  throw new Error(`Max retries exceeded for ${url}`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// ─── Pool Operator Client ───────────────────────────────────────────────────

export class PoolOperatorClient {
  private cfg: Required<PoolOperatorConfig>;
  private minerAddress: string = '';
  private auth: AuthTokenManager | null = null;
  private poolIface: ethers.Interface;
  private minedEpochs: Set<number> = new Set();

  constructor(config: PoolOperatorConfig) {
    this.cfg = {
      coordinatorUrl: 'https://coordinator.agentmoney.net',
      chainId: 8453,
      maxFailures: 5,
      loopDelayMs: 5_000,
      ...config,
    };
    this.poolIface = new ethers.Interface(POOL_ABI);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  Setup
  // ══════════════════════════════════════════════════════════════════════════

  /** Resolve wallet from Bankr and initialize auth */
  async initialize(): Promise<string> {
    // Get operator's wallet from Bankr
    const meRes = await fetch('https://api.bankr.bot/agent/me', {
      headers: { 'X-API-Key': this.cfg.bankrApiKey },
    });
    if (!meRes.ok) {
      throw new Error(`Bankr /agent/me failed (${meRes.status})`);
    }
    const meData = await meRes.json();

    // Extract EVM address
    const wallets = meData.wallets || meData.addresses || [];
    const evmWallet = wallets.find(
      (w: any) => w.chain === 'base' || w.chain === 'evm' || w.address?.startsWith('0x'),
    );
    this.minerAddress = evmWallet?.address || meData.address;
    if (!this.minerAddress) {
      throw new Error('Could not resolve EVM wallet from Bankr');
    }

    // Auth as the POOL CONTRACT address (not the operator EOA).
    // The coordinator authenticates the pool via EIP-1271: it calls
    // pool.isValidSignature(digest, signature) and the pool verifies
    // that the signature came from the operator.
    this.auth = new AuthTokenManager(
      this.cfg.coordinatorUrl,
      this.cfg.poolContractAddress,
      this.cfg.bankrApiKey,
    );

    console.log(`Operator wallet: ${this.minerAddress}`);
    console.log(`Pool contract (miner identity): ${this.cfg.poolContractAddress}`);
    return this.minerAddress;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  Coordinator API
  // ══════════════════════════════════════════════════════════════════════════

  /** GET /v1/epoch — current epoch info */
  async getEpochInfo(): Promise<EpochInfo> {
    const res = await fetchWithRetry(`${this.cfg.coordinatorUrl}/v1/epoch`, {
      method: 'GET',
    });
    return res.json();
  }

  /** GET /v1/credits?miner=X — credits per epoch for this pool */
  async getCredits(): Promise<CreditsInfo> {
    const res = await fetchWithRetry(
      `${this.cfg.coordinatorUrl}/v1/credits?miner=${this.cfg.poolContractAddress}`,
      { method: 'GET' },
    );
    return res.json();
  }

  /** GET /v1/token — BOTCOIN token address (for verification) */
  async getTokenAddress(): Promise<string> {
    const res = await fetchWithRetry(`${this.cfg.coordinatorUrl}/v1/token`, {
      method: 'GET',
    });
    const data = await res.json();
    return data.address || data.token;
  }

  /** GET /v1/challenge?miner=X&nonce=Y — request a challenge */
  async fetchChallenge(): Promise<{ challenge: ChallengePackage; nonce: string }> {
    const token = await this.auth!.getToken();
    const nonce = crypto.randomUUID?.() || Math.random().toString(36).slice(2, 34);

    const res = await fetchWithRetry(
      `${this.cfg.coordinatorUrl}/v1/challenge?miner=${this.cfg.poolContractAddress}&nonce=${nonce}`,
      {
        method: 'GET',
        headers: { Authorization: `Bearer ${token}` },
      },
    );

    if (res.status === 401) {
      this.auth!.invalidate();
      throw new Error('AUTH_EXPIRED');
    }
    if (res.status === 403) {
      throw new Error('INSUFFICIENT_BALANCE');
    }
    if (!res.ok) {
      throw new Error(`Challenge request failed: ${res.status} ${await res.text()}`);
    }

    const challenge: ChallengePackage = await res.json();
    return { challenge, nonce };
  }

  /** POST /v1/submit — submit solved artifact */
  async submitSolve(
    challengeId: string,
    artifact: string,
    nonce: string,
  ): Promise<SubmitResult> {
    const token = await this.auth!.getToken();

    const res = await fetchWithRetry(`${this.cfg.coordinatorUrl}/v1/submit`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        miner: this.cfg.poolContractAddress,
        challengeId,
        artifact,
        nonce,
      }),
    });

    if (res.status === 401) {
      this.auth!.invalidate();
      throw new Error('AUTH_EXPIRED');
    }
    if (res.status === 404) {
      throw new Error('STALE_CHALLENGE');
    }
    if (!res.ok) {
      throw new Error(`Submit failed: ${res.status} ${await res.text()}`);
    }

    return res.json();
  }

  /** GET /v1/claim-calldata?epochs=X,Y — get pre-encoded claim calldata */
  async getClaimCalldata(epochIds: number[]): Promise<TransactionData> {
    const epochs = epochIds.join(',');
    const res = await fetchWithRetry(
      `${this.cfg.coordinatorUrl}/v1/claim-calldata?epochs=${epochs}`,
      { method: 'GET' },
    );
    if (!res.ok) {
      throw new Error(`Claim calldata failed: ${res.status} ${await res.text()}`);
    }
    const data = await res.json();
    return data.transaction;
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  Transaction Wrapping
  //
  //  The coordinator returns transactions targeting the MINING CONTRACT.
  //  For a pool, we must wrap them so they go through the POOL CONTRACT:
  //    - Receipts  → pool.submitReceiptToMining(calldata)
  //    - Claims    → pool.claimEpochReward(epochId, calldata)
  //
  //  The pool then forwards the inner calldata to the mining contract, so
  //  msg.sender == pool address (not the operator EOA).
  // ══════════════════════════════════════════════════════════════════════════

  /** Wrap coordinator receipt calldata into pool.submitReceiptToMining(calldata) */
  private wrapReceipt(coordinatorTx: TransactionData): TransactionData {
    const wrappedData = this.poolIface.encodeFunctionData('submitReceiptToMining', [
      coordinatorTx.data,
    ]);
    return {
      to: this.cfg.poolContractAddress,
      chainId: this.cfg.chainId,
      value: '0',
      data: wrappedData,
    };
  }

  /** Wrap coordinator claim calldata into pool.claimEpochReward(epochId, calldata) */
  private wrapClaim(epochId: number, coordinatorTx: TransactionData): TransactionData {
    const wrappedData = this.poolIface.encodeFunctionData('claimEpochReward', [
      epochId,
      coordinatorTx.data,
    ]);
    return {
      to: this.cfg.poolContractAddress,
      chainId: this.cfg.chainId,
      value: '0',
      data: wrappedData,
    };
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  Bankr Transaction Submission
  // ══════════════════════════════════════════════════════════════════════════

  /**
   * Submit a raw transaction via Bankr POST /agent/submit.
   * Uses waitForConfirmation: true → synchronous, no job polling.
   */
  private async submitTx(tx: TransactionData, description: string): Promise<BankrTxResult> {
    const res = await fetch('https://api.bankr.bot/agent/submit', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-API-Key': this.cfg.bankrApiKey,
      },
      body: JSON.stringify({
        transaction: {
          to: tx.to,
          chainId: tx.chainId,
          value: tx.value || '0',
          data: tx.data,
        },
        description,
        waitForConfirmation: true,
      }),
    });

    if (res.status === 401) throw new Error('Bankr API key invalid');
    if (res.status === 403) throw new Error('Bankr API key lacks write/agent access');
    if (res.status === 429) {
      await sleep(60_000);
      return this.submitTx(tx, description); // retry once after cooldown
    }

    return res.json();
  }

  /** Post a mining receipt on-chain (wrapped through pool) */
  async postReceipt(coordinatorTx: TransactionData): Promise<BankrTxResult> {
    const poolTx = this.wrapReceipt(coordinatorTx);
    return this.submitTx(poolTx, 'Post BOTCOIN mining receipt via pool');
  }

  /** Claim rewards for a single epoch (wrapped through pool) */
  async claimEpochRewards(epochId: number): Promise<BankrTxResult> {
    const coordinatorTx = await this.getClaimCalldata([epochId]);
    const poolTx = this.wrapClaim(epochId, coordinatorTx);
    return this.submitTx(poolTx, `Claim BOTCOIN pool rewards (epoch ${epochId})`);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  Mining Loop
  // ══════════════════════════════════════════════════════════════════════════

  /** Run the continuous mining loop */
  async runMiningLoop(): Promise<void> {
    if (!this.auth) throw new Error('Call initialize() first');

    console.log('Starting mining loop...');
    let consecutiveFailures = 0;

    while (consecutiveFailures < this.cfg.maxFailures) {
      try {
        // 1. Request challenge
        console.log('\n─── Requesting challenge ───');
        const { challenge, nonce } = await this.fetchChallenge();
        console.log(
          `Epoch: ${challenge.epochId} | ` +
            `Credits/solve: ${challenge.creditsPerSolve} | ` +
            `Constraints: ${challenge.constraints.length} | ` +
            `Companies: ${challenge.companies.length}`,
        );
        this.minedEpochs.add(challenge.epochId);

        // 2. Solve with LLM
        console.log('Solving...');
        const t0 = Date.now();
        const artifact = await this.cfg.solveFn(challenge);
        const solveMs = Date.now() - t0;
        console.log(`Solved in ${(solveMs / 1000).toFixed(1)}s (${artifact.slice(0, 60)}...)`);

        // 3. Submit to coordinator
        console.log('Submitting to coordinator...');
        const result = await this.submitSolve(challenge.challengeId, artifact, nonce);

        if (result.pass && result.transaction) {
          // 4. Post receipt on-chain (WRAPPED through pool contract)
          console.log('✅ PASS — posting receipt on-chain via pool...');
          const txResult = await this.postReceipt(result.transaction);

          if (txResult.success) {
            console.log(`Receipt posted: ${txResult.transactionHash}`);
            consecutiveFailures = 0;
          } else {
            console.error(`Receipt tx failed: ${txResult.error}`);
            consecutiveFailures++;
          }
        } else {
          console.log(
            `❌ FAIL — constraints: [${result.failedConstraintIndices?.join(', ') || '?'}]`,
          );
          consecutiveFailures++;
        }
      } catch (err: any) {
        if (err.message === 'AUTH_EXPIRED') {
          console.log('Auth expired, refreshing token...');
          try {
            await this.auth.refresh();
          } catch (authErr: any) {
            if (authErr.message === 'INSUFFICIENT_BALANCE') {
              console.error('Pool has insufficient BOTCOIN balance. Fund pool first.');
              break;
            }
            throw authErr;
          }
          continue;
        }
        if (err.message === 'INSUFFICIENT_BALANCE') {
          console.error('Pool has insufficient BOTCOIN balance. Fund pool first.');
          break;
        }
        if (err.message === 'STALE_CHALLENGE') {
          console.log('Stale challenge (epoch may have advanced), fetching new one...');
          continue;
        }
        console.error('Mining loop error:', err.message || err);
        consecutiveFailures++;
      }

      await sleep(this.cfg.loopDelayMs);
    }

    if (consecutiveFailures >= this.cfg.maxFailures) {
      console.error(
        `\nStopped after ${this.cfg.maxFailures} consecutive failures.\n` +
          'Check model selection or increase thinking budget.',
      );
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  Reward Claims
  // ══════════════════════════════════════════════════════════════════════════

  /** Check for claimable epochs and claim them one at a time */
  async checkAndClaimRewards(): Promise<void> {
    const epochInfo = await this.getEpochInfo();
    const credits = await this.getCredits();

    console.log(`Current epoch: ${epochInfo.epochId}`);
    console.log(`Credits by epoch: ${JSON.stringify(credits.epochs)}`);

    const claimable: number[] = [];
    for (const [epochStr, creditCount] of Object.entries(credits.epochs)) {
      const epochId = parseInt(epochStr);
      if (epochId < epochInfo.epochId && creditCount > 0) {
        claimable.push(epochId);
      }
    }

    if (claimable.length === 0) {
      console.log('No claimable epochs found.');
      return;
    }

    // Claim per-epoch for exact proportional accounting in pool contract
    for (const epochId of claimable.sort((a, b) => a - b)) {
      console.log(`Claiming epoch ${epochId}...`);
      try {
        const result = await this.claimEpochRewards(epochId);
        if (result.success) {
          console.log(`✅ Epoch ${epochId} claimed: ${result.transactionHash}`);
        } else {
          console.log(`Epoch ${epochId}: ${result.error || 'reverted'} (may not be funded yet)`);
        }
      } catch (err: any) {
        console.error(`Error claiming epoch ${epochId}:`, err.message);
      }
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  Health Check
  // ══════════════════════════════════════════════════════════════════════════

  async healthCheck(): Promise<{
    wallet: string;
    pool: string;
    epoch: EpochInfo;
    authValid: boolean;
    tokenAddress: string;
  }> {
    const [epoch, tokenAddress] = await Promise.all([
      this.getEpochInfo(),
      this.getTokenAddress(),
    ]);

    let authValid = false;
    try {
      await this.auth!.getToken();
      authValid = true;
    } catch {}

    return {
      wallet: this.minerAddress,
      pool: this.cfg.poolContractAddress,
      epoch,
      authValid,
      tokenAddress,
    };
  }

  /** Epochs this operator mined in (this session) */
  getMinedEpochs(): number[] {
    return [...this.minedEpochs].sort((a, b) => a - b);
  }
}
