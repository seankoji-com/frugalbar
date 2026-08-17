import React, { useState, useEffect, useMemo, useCallback } from 'react';
import { 
  INITIAL_QUOTA_SNAPSHOTS, 
  INITIAL_APP_SETTINGS 
} from './data/initialData';
import { 
  QuotaSnapshot, 
  AppSettings, 
  ProviderStatus, 
  SystemHealthSummary 
} from './types';
import { PopoverRootView } from './components/PopoverRootView';
import { MacMenuBar } from './components/MacMenuBar';
import { MetricDetailModal } from './components/MetricDetailModal';
import { SettingsModal } from './components/SettingsModal';
import { soundManager } from './utils/audio';
import { 
  Gauge, 
  Sliders, 
  Copy, 
  Check, 
  Maximize2, 
  Minimize2, 
  Sparkles, 
  Zap, 
  AlertTriangle, 
  RefreshCw, 
  Eye,
  Info
} from 'lucide-react';

export default function App() {
  const [snapshots, setSnapshots] = useState<QuotaSnapshot[]>(INITIAL_QUOTA_SNAPSHOTS);
  const [settings, setSettings] = useState<AppSettings>(INITIAL_APP_SETTINGS);
  const [isPopoverOpen, setIsPopoverOpen] = useState(true);
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [selectedSnapshot, setSelectedSnapshot] = useState<QuotaSnapshot | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const [lastUpdatedMinutes, setLastUpdatedMinutes] = useState(2);
  const [wallpaper, setWallpaper] = useState<'sonoma' | 'obsidian' | 'studio'>('sonoma');
  const [copiedReport, setCopiedReport] = useState(false);
  const [activeScenario, setActiveScenario] = useState<'default' | 'allHealthy' | 'spike' | 'exhausted'>('default');

  // Compute aggregate system health
  const healthSummary = useMemo<SystemHealthSummary>(() => {
    let worstFraction = 0;
    let worstVendor = '';
    let criticalCount = 0;
    let warningCount = 0;
    let healthyCount = 0;

    snapshots.forEach((s) => {
      const p1 = s.row1.primaryFraction;
      const p2 = s.row2?.primaryFraction || 0;
      const maxUsed = Math.max(p1, p2);

      if (maxUsed > worstFraction) {
        worstFraction = maxUsed;
        worstVendor = s.displayName;
      }

      if (s.status === 'critical' || maxUsed >= (settings.criticalThreshold / 100)) {
        criticalCount++;
      } else if (s.status === 'warning' || maxUsed >= (settings.warningThreshold / 100)) {
        warningCount++;
      } else {
        healthyCount++;
      }
    });

    let overallStatus: ProviderStatus = 'healthy';
    if (criticalCount > 0) {
      overallStatus = 'critical';
    } else if (warningCount > 0) {
      overallStatus = 'warning';
    }

    return {
      overallStatus,
      healthyCount,
      warningCount,
      criticalCount,
      worstUsageVendor: worstVendor,
      worstUsageFraction: worstFraction,
    };
  }, [snapshots, settings.criticalThreshold, settings.warningThreshold]);

  // Refresh handler (simulates parallel Swift TaskGroup fetch with 4s timeout protection)
  const handleRefresh = useCallback(() => {
    setIsRefreshing(true);
    soundManager.playRefreshSound();

    setTimeout(() => {
      setSnapshots((prev) =>
        prev.map((item) => {
          // Slight jitter to simulate live traffic
          const jitter = (Math.random() - 0.5) * 0.04;
          const newP1 = Math.max(0.05, Math.min(0.99, item.row1.primaryFraction + jitter));
          const newLatency = Math.floor(60 + Math.random() * 110);
          
          let newStatus = item.status;
          if (newP1 >= settings.criticalThreshold / 100) {
            newStatus = 'critical';
          } else if (newP1 >= settings.warningThreshold / 100) {
            newStatus = 'warning';
          } else {
            newStatus = 'healthy';
          }

          return {
            ...item,
            latencyMs: newLatency,
            lastUpdated: 'Just now',
            status: newStatus,
            row1: {
              ...item.row1,
              primaryFraction: newP1,
            },
          };
        })
      );
      setLastUpdatedMinutes(0);
      setIsRefreshing(false);
    }, 600);
  }, [settings.criticalThreshold, settings.warningThreshold]);

  // Auto-refresh interval
  useEffect(() => {
    const intervalMs = settings.refreshIntervalSeconds * 1000;
    const timer = setInterval(() => {
      handleRefresh();
    }, intervalMs);

    const minuteTimer = setInterval(() => {
      setLastUpdatedMinutes((m) => m + 1);
    }, 60000);

    return () => {
      clearInterval(timer);
      clearInterval(minuteTimer);
    };
  }, [settings.refreshIntervalSeconds, handleRefresh]);

  // Keyboard shortcut listener (Cmd+Shift+Q or Escape)
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.shiftKey && (e.key === 'q' || e.key === 'Q')) {
        e.preventDefault();
        soundManager.playClickSound();
        setIsPopoverOpen((prev) => !prev);
      } else if (e.key === 'Escape') {
        if (selectedSnapshot) setSelectedSnapshot(null);
        else if (isSettingsOpen) setIsSettingsOpen(false);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [selectedSnapshot, isSettingsOpen]);

  // Update specific usage from detail slider
  const handleUpdateUsage = (id: string, newPrimary: number) => {
    setSnapshots((prev) =>
      prev.map((s) => {
        if (s.id !== id) return s;
        let newStatus: ProviderStatus = 'healthy';
        if (newPrimary >= settings.criticalThreshold / 100) {
          newStatus = 'critical';
        } else if (newPrimary >= settings.warningThreshold / 100) {
          newStatus = 'warning';
        }
        return {
          ...s,
          status: newStatus,
          row1: {
            ...s.row1,
            primaryFraction: newPrimary,
            usedText: `${(newPrimary * 100).toFixed(0)}% used`,
          },
        };
      })
    );
  };

  // Scenario presets for quick testing
  const applyScenario = (scenario: 'default' | 'allHealthy' | 'spike' | 'exhausted') => {
    setActiveScenario(scenario);
    soundManager.playClickSound();
    if (scenario === 'default') {
      setSnapshots(INITIAL_QUOTA_SNAPSHOTS);
    } else if (scenario === 'allHealthy') {
      setSnapshots((prev) =>
        prev.map((s) => ({
          ...s,
          status: 'healthy',
          row1: { ...s.row1, primaryFraction: 0.25, usedText: '25% used' },
          row2: s.row2 ? { ...s.row2, primaryFraction: 0.30, usedText: '30% used' } : undefined,
        }))
      );
    } else if (scenario === 'spike') {
      setSnapshots((prev) =>
        prev.map((s) => {
          if (s.vendorId === 'claude' || s.vendorId === 'openrouter') {
            return {
              ...s,
              status: 'critical',
              row1: { ...s.row1, primaryFraction: 0.94, usedText: '94% limit surge' },
            };
          }
          return s;
        })
      );
    } else if (scenario === 'exhausted') {
      setSnapshots((prev) =>
        prev.map((s) => ({
          ...s,
          status: 'critical',
          row1: { ...s.row1, primaryFraction: 0.98, usedText: '98% exhausted' },
          row2: s.row2 ? { ...s.row2, primaryFraction: 0.92, usedText: '92% exhausted' } : undefined,
        }))
      );
    }
  };

  // Copy Markdown status report
  const handleCopyReport = () => {
    const lines = [
      `# QuotaBar Status Report (${new Date().toLocaleTimeString()})`,
      `**System Status**: ${healthSummary.overallStatus.toUpperCase()}`,
      `**Worst Usage**: ${healthSummary.worstUsageVendor} (${(healthSummary.worstUsageFraction * 100).toFixed(0)}%)`,
      '',
      '| Provider | Category | 5H Usage | Status | Resets |',
      '| :--- | :--- | :--- | :--- | :--- |',
      ...snapshots.map(
        (s) =>
          `| ${s.displayName} | ${s.category} | ${(s.row1.primaryFraction * 100).toFixed(0)}% | ${s.status} | ${s.resetsInFormatted} |`
      ),
    ];
    navigator.clipboard.writeText(lines.join('\n'));
    soundManager.playClickSound();
    setCopiedReport(true);
    setTimeout(() => setCopiedReport(false), 2000);
  };

  // Wallpaper backgrounds
  const bgClass =
    wallpaper === 'sonoma'
      ? 'bg-[radial-gradient(ellipse_80%_80%_at_50%_-20%,rgba(120,119,198,0.25),rgba(255,255,255,0))] bg-[#0b0c0e]'
      : wallpaper === 'obsidian'
      ? 'bg-[#050608]'
      : 'bg-[radial-gradient(circle_at_top,_var(--tw-gradient-stops))] from-[#1a1c23] via-[#0d0e12] to-[#050507]';

  return (
    <div className={`min-h-screen w-full flex flex-col ${bgClass} text-[#e3e2e7] relative select-none font-['Inter',sans-serif] overflow-x-hidden`}>
      {/* 1. macOS Menu Bar Simulation at Top */}
      <MacMenuBar
        overallStatus={healthSummary.overallStatus}
        worstUsagePercentage={Math.round(healthSummary.worstUsageFraction * 100)}
        isPopoverOpen={isPopoverOpen}
        settings={settings}
        onTogglePopover={() => setIsPopoverOpen((prev) => !prev)}
        onRefreshAll={handleRefresh}
      />

      {/* 2. Main Desktop Stage */}
      <div className="flex-1 flex flex-col items-center justify-center p-4 relative">
        {/* Popover Display Container */}
        <div className="relative z-20 flex flex-col items-center">
          {/* Subtle pointer notch when attached under the menu bar */}
          {isPopoverOpen && (
            <div className="w-3 h-1.5 bg-[#1a1b1f] border-t border-l border-white/20 rotate-45 mb-[-3px] z-30 shadow-md rounded-[1px]" />
          )}

          {isPopoverOpen ? (
            <div className="transition-all duration-300 transform scale-100 opacity-100 shadow-2xl">
              <PopoverRootView
                snapshots={snapshots}
                overallStatus={healthSummary.overallStatus}
                lastUpdatedText={lastUpdatedMinutes === 0 ? 'Just now' : `${lastUpdatedMinutes}m`}
                isRefreshing={isRefreshing}
                onRefresh={handleRefresh}
                onOpenSettings={() => setIsSettingsOpen(true)}
                onSelectSnapshot={(snapshot) => setSelectedSnapshot(snapshot)}
                onQuitApp={() => setIsPopoverOpen(false)}
              />
            </div>
          ) : (
            <div className="flex flex-col items-center justify-center py-16 px-6 text-center max-w-sm bg-black/40 backdrop-blur-xl border border-white/10 rounded-2xl p-8 shadow-2xl animate-in fade-in zoom-in-95">
              <div className="w-12 h-12 rounded-2xl bg-white/10 border border-white/15 flex items-center justify-center text-[#adc6ff] mb-3 shadow-inner">
                <Gauge size={24} />
              </div>
              <h2 className="text-sm font-semibold text-white">QuotaBar is Running in Menu Bar</h2>
              <p className="text-xs text-[#c1c6d7]/70 mt-1 mb-4 leading-relaxed">
                Click the Gauge icon in the top macOS menu bar or use the shortcut to open the zero-scroll popover.
              </p>
              <button
                type="button"
                onClick={() => {
                  soundManager.playClickSound();
                  setIsPopoverOpen(true);
                }}
                className="px-4 py-2 bg-[#adc6ff] hover:bg-[#d8e2ff] text-black text-xs font-semibold rounded-lg transition-all shadow-md active:scale-95 flex items-center gap-1.5"
              >
                <span>Open Popover</span>
                <kbd className="text-[10px] bg-black/20 px-1 py-0.5 rounded font-mono">⌘⇧Q</kbd>
              </button>
            </div>
          )}
        </div>

        {/* 3. Developer Testing & Control Bar */}
        <div className="mt-8 z-10 w-full max-w-xl bg-black/50 backdrop-blur-xl border border-white/10 rounded-xl p-3 shadow-lg flex flex-col gap-2.5">
          <div className="flex items-center justify-between border-b border-white/10 pb-2">
            <div className="flex items-center gap-2">
              <Sparkles size={13} className="text-[#adc6ff]" />
              <span className="text-[11px] font-semibold text-white">Interactive Playground & Stress Testing</span>
            </div>
            <div className="flex items-center gap-1">
              <button
                type="button"
                onClick={handleCopyReport}
                className="flex items-center gap-1 px-2 py-1 bg-white/5 hover:bg-white/10 text-[10px] text-[#c1c6d7] hover:text-white rounded border border-white/5 transition-colors"
                title="Copy formatted Markdown table"
              >
                {copiedReport ? <Check size={11} className="text-[#53e16f]" /> : <Copy size={11} />}
                <span>{copiedReport ? 'Copied' : 'Export Report'}</span>
              </button>
              <button
                type="button"
                onClick={() => setIsSettingsOpen(true)}
                className="p-1 text-[#c1c6d7] hover:text-white hover:bg-white/10 rounded border border-white/5 transition-colors"
                title="Open Settings"
              >
                <Sliders size={12} />
              </button>
            </div>
          </div>

          {/* Preset buttons */}
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-1.5">
            <button
              type="button"
              onClick={() => applyScenario('default')}
              className={`py-1 px-2 rounded text-[10px] font-medium border text-center transition-all ${
                activeScenario === 'default'
                  ? 'bg-white/15 border-white/30 text-white'
                  : 'bg-black/30 border-white/5 text-[#c1c6d7] hover:bg-white/5'
              }`}
            >
              Exact Spec (Ref)
            </button>
            <button
              type="button"
              onClick={() => applyScenario('allHealthy')}
              className={`py-1 px-2 rounded text-[10px] font-medium border text-center transition-all ${
                activeScenario === 'allHealthy'
                  ? 'bg-[#53e16f]/20 border-[#53e16f]/40 text-[#53e16f]'
                  : 'bg-black/30 border-white/5 text-[#c1c6d7] hover:bg-white/5'
              }`}
            >
              All Healthy (25%)
            </button>
            <button
              type="button"
              onClick={() => applyScenario('spike')}
              className={`py-1 px-2 rounded text-[10px] font-medium border text-center transition-all ${
                activeScenario === 'spike'
                  ? 'bg-[#ffb874]/20 border-[#ffb874]/40 text-[#ffb874]'
                  : 'bg-black/30 border-white/5 text-[#c1c6d7] hover:bg-white/5'
              }`}
            >
              Claude/OR Surge
            </button>
            <button
              type="button"
              onClick={() => applyScenario('exhausted')}
              className={`py-1 px-2 rounded text-[10px] font-medium border text-center transition-all ${
                activeScenario === 'exhausted'
                  ? 'bg-[#ffb4ab]/20 border-[#ffb4ab]/40 text-[#ffb4ab]'
                  : 'bg-black/30 border-white/5 text-[#c1c6d7] hover:bg-white/5'
              }`}
            >
              Critical Exhaustion
            </button>
          </div>

          {/* Quick Specs summary */}
          <div className="flex flex-wrap items-center justify-between gap-2 pt-1 text-[9px] text-[#c1c6d7]/70 font-mono">
            <span className="flex items-center gap-1">
              <span className="w-1.5 h-1.5 rounded-full bg-[#53e16f]" />
              7 Providers Monitored
            </span>
            <span>Zero-Scroll 340×410pt Geometry</span>
            <span>&lt;25MB Mem • 4.0s Timeout Guards</span>
          </div>
        </div>
      </div>

      {/* 4. Detail Inspector Modal */}
      <MetricDetailModal
        snapshot={selectedSnapshot}
        onClose={() => setSelectedSnapshot(null)}
        onUpdateUsage={handleUpdateUsage}
      />

      {/* 5. Preferences Modal */}
      <SettingsModal
        isOpen={isSettingsOpen}
        settings={settings}
        onClose={() => setIsSettingsOpen(false)}
        onSave={(newSettings) => setSettings(newSettings)}
        onResetAllData={() => setSnapshots(INITIAL_QUOTA_SNAPSHOTS)}
      />
    </div>
  );
}
