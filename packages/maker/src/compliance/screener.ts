// Compliance screener interface — pluggable for Chainalysis/TRM later

export interface ScreenResult {
  allowed: boolean;
  reason?: string;
  riskTier: "clean" | "unknown" | "flagged";
}

export interface ComplianceScreener {
  screen(address: string, chainId: number): Promise<ScreenResult>;
}

// v0.1 stub: allowlist/denylist from config
export class AllowlistScreener implements ComplianceScreener {
  private allowlist: Set<string>;
  private denylist: Set<string>;

  constructor(allowlist: string[] = [], denylist: string[] = []) {
    this.allowlist = new Set(allowlist.map((a) => a.toLowerCase()));
    this.denylist = new Set(denylist.map((a) => a.toLowerCase()));
  }

  async screen(address: string): Promise<ScreenResult> {
    const addr = address.toLowerCase();

    if (this.denylist.has(addr)) {
      return { allowed: false, reason: "Address on denylist", riskTier: "flagged" };
    }

    if (this.allowlist.size > 0 && this.allowlist.has(addr)) {
      return { allowed: true, riskTier: "clean" };
    }

    // If no allowlist configured, allow all non-denied addresses as "unknown"
    if (this.allowlist.size === 0) {
      return { allowed: true, riskTier: "unknown" };
    }

    return { allowed: false, reason: "Address not on allowlist", riskTier: "unknown" };
  }
}
