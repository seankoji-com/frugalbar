export type VendorIdentifier = 
  | 'claude' 
  | 'gemini' 
  | 'opencode' 
  | 'copilot' 
  | 'openrouter' 
  | 'github_rest' 
  | 'github_graphql';

export type MetricCategory = 
  | 'AI Subscriptions' 
  | 'API Spend & Credits' 
  | 'Developer Limits';

export type ProviderStatus = 
  | 'healthy' 
  | 'warning' 
  | 'critical' 
  | 'unauthenticated' 
  | 'rateLimited' 
  | 'networkError';

export interface DualBarMetrics {
  primaryFraction: number; // 0.0 to 1.0
  secondaryFraction?: number; // secondary accent / surge fraction (e.g. in HTML)
  label: string; // e.g. '5H'
  statusColor?: string; // override color if needed
  usedText?: string;
  resetText?: string;
}

export interface QuotaSnapshot {
  id: string;
  vendorId: VendorIdentifier;
  displayName: string;
  category: MetricCategory;
  iconUrl: string;
  accentColor: string;
  badgeText?: string;
  status: ProviderStatus;
  statusText: string;
  
  // Dual-bar representation (e.g. 5H vs WK or REST vs GraphQL)
  row1: DualBarMetrics;
  row2?: DualBarMetrics;

  // Granular details for inspector
  currentUsageFormatted: string;
  totalLimitFormatted: string;
  resetsInFormatted: string;
  costSpentFormatted?: string;
  balanceRemainingFormatted?: string;
  planName?: string;
  latencyMs: number;
  cliSource?: string;
  keyMasked?: string;
  lastUpdated: string;
  auxiliaryNotes?: string;
}

export interface AppSettings {
  refreshIntervalSeconds: number;
  warningThreshold: number; // 0-100
  criticalThreshold: number; // 0-100
  menuBarMode: 'gauge' | 'percentage' | 'compact';
  launchAtLogin: boolean;
  soundAlerts: boolean;
  hapticFeedback: boolean;
  compactDensity: boolean;
  apiKeys: {
    claudeKey: string;
    geminiKey: string;
    openRouterKey: string;
    githubPat: string;
    openCodeToken: string;
  };
  cliDiscoveryEnabled: boolean;
}

export interface SystemHealthSummary {
  overallStatus: ProviderStatus;
  healthyCount: number;
  warningCount: number;
  criticalCount: number;
  worstUsageVendor: string;
  worstUsageFraction: number;
}
