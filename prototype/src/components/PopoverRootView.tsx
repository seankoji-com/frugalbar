import React, { useState } from 'react';
import { RotateCw, Settings, Power } from 'lucide-react';
import { QuotaSnapshot, ProviderStatus } from '../types';
import { MetricRowView } from './MetricRowView';
import { soundManager } from '../utils/audio';

interface PopoverRootViewProps {
  snapshots: QuotaSnapshot[];
  overallStatus: ProviderStatus;
  lastUpdatedText: string;
  isRefreshing: boolean;
  onRefresh: () => void;
  onOpenSettings: () => void;
  onSelectSnapshot: (snapshot: QuotaSnapshot) => void;
  onQuitApp?: () => void;
}

export const PopoverRootView: React.FC<PopoverRootViewProps> = ({
  snapshots,
  overallStatus,
  lastUpdatedText,
  isRefreshing,
  onRefresh,
  onOpenSettings,
  onSelectSnapshot,
  onQuitApp,
}) => {
  const [isRotating, setIsRotating] = useState(false);

  const aiSubscriptions = snapshots.filter((s) => s.category === 'AI Subscriptions');
  const apiSpend = snapshots.filter((s) => s.category === 'API Spend & Credits');
  const devLimits = snapshots.filter((s) => s.category === 'Developer Limits');

  const handleRefreshClick = () => {
    setIsRotating(true);
    soundManager.playRefreshSound();
    onRefresh();
    setTimeout(() => setIsRotating(false), 800);
  };

  // Compute status badge in header
  const getStatusBadge = () => {
    if (overallStatus === 'critical') {
      return (
        <div className="flex items-center gap-1.5 text-[#ffb4ab] text-[9px] font-medium tracking-tight">
          <span className="w-1.5 h-1.5 rounded-full bg-[#ffb4ab] shadow-[0_0_6px_rgba(255,180,171,0.8)] animate-pulse" />
          Critical Limits
        </div>
      );
    }
    if (overallStatus === 'warning') {
      return (
        <div className="flex items-center gap-1.5 text-[#ffb874] text-[9px] font-medium tracking-tight">
          <span className="w-1.5 h-1.5 rounded-full bg-[#ffb874] shadow-[0_0_4px_rgba(255,184,116,0.6)]" />
          High Usage Detected
        </div>
      );
    }
    return (
      <div className="flex items-center gap-1.5 text-[#53e16f] text-[9px] font-medium tracking-tight">
        <span className="w-1.5 h-1.5 rounded-full bg-[#53e16f] shadow-[0_0_4px_rgba(83,225,111,0.6)]" />
        All Systems Normal
      </div>
    );
  };

  return (
    <div className="relative w-[340px] h-[410px] bg-[#121317]/90 backdrop-blur-2xl border-[0.5px] border-white/10 rounded-xl overflow-hidden shadow-2xl flex flex-col select-none text-[#e3e2e7] font-['Inter',sans-serif]">
      {/* Top App Bar (Header) */}
      <header className="flex justify-between items-center h-8 px-3 w-[340px] bg-[#1a1b1f]/95 border-b-[0.5px] border-[#414755]/60 flex-shrink-0 z-10">
        <div className="text-[12px] font-semibold text-[#e3e2e7] tracking-tight flex items-center gap-1.5">
          <span>QuotaBar</span>
        </div>

        {/* Global Health Status */}
        {getStatusBadge()}

        {/* Refresh & Last Updated */}
        <div className="flex items-center gap-1.5 text-[#c1c6d7] text-[9px]">
          <span className="opacity-80">{lastUpdatedText}</span>
          <button
            type="button"
            onClick={handleRefreshClick}
            disabled={isRefreshing}
            aria-label="Refresh Quotas"
            title="Refresh All Provider Snapshots"
            className="p-1 -mr-1 rounded hover:bg-white/10 active:scale-95 text-[#c1c6d7] hover:text-[#e3e2e7] transition-all cursor-pointer"
          >
            <RotateCw
              size={12}
              className={`${isRotating || isRefreshing ? 'animate-spin text-[#adc6ff]' : ''}`}
            />
          </button>
        </div>
      </header>

      {/* Main Content: High-density Zero-scroll list */}
      <main className="flex-1 flex flex-col px-3 py-2 gap-2.5 overflow-hidden z-0 bg-[#121317]/50 pb-8">
        {/* Section 1: AI SUBSCRIPTIONS */}
        <section className="flex flex-col gap-1.5">
          <h2 className="text-[10px] font-bold text-[#c1c6d7]/80 uppercase pb-[2px] border-b-[0.5px] border-[#414755]/40 tracking-wider">
            AI SUBSCRIPTIONS
          </h2>
          <div className="flex flex-col gap-0.5">
            {aiSubscriptions.map((snapshot) => (
              <MetricRowView
                key={snapshot.id}
                snapshot={snapshot}
                onSelect={onSelectSnapshot}
              />
            ))}
          </div>
        </section>

        {/* Section 2: API SPEND & CREDITS */}
        <section className="flex flex-col gap-1.5">
          <h2 className="text-[10px] font-bold text-[#c1c6d7]/80 uppercase pb-[2px] border-b-[0.5px] border-[#414755]/40 tracking-wider">
            API SPEND & CREDITS
          </h2>
          <div className="flex flex-col gap-0.5">
            {apiSpend.map((snapshot) => (
              <MetricRowView
                key={snapshot.id}
                snapshot={snapshot}
                onSelect={onSelectSnapshot}
              />
            ))}
          </div>
        </section>

        {/* Section 3: DEVELOPER LIMITS */}
        <section className="flex flex-col gap-1.5">
          <h2 className="text-[10px] font-bold text-[#c1c6d7]/80 uppercase pb-[2px] border-b-[0.5px] border-[#414755]/40 tracking-wider">
            DEVELOPER LIMITS
          </h2>
          <div className="flex flex-col gap-0.5">
            {devLimits.map((snapshot) => (
              <MetricRowView
                key={snapshot.id}
                snapshot={snapshot}
                isGrayscale={true}
                onSelect={onSelectSnapshot}
              />
            ))}
          </div>
        </section>
      </main>

      {/* Footer */}
      <footer className="absolute bottom-0 left-0 w-[340px] flex justify-between items-center h-7 px-3 bg-[#0d0e12]/90 backdrop-blur-md border-t-[0.5px] border-[#414755]/60 z-10">
        <button
          type="button"
          onClick={() => {
            soundManager.playClickSound();
            onOpenSettings();
          }}
          className="flex items-center text-[#c1c6d7] text-[10px] hover:text-[#e3e2e7] transition-colors cursor-pointer group py-0.5"
        >
          <Settings size={12} className="mr-1 opacity-70 group-hover:opacity-100 group-hover:rotate-45 transition-all" />
          <span>Preferences</span>
        </button>

        <div className="flex items-center gap-3 text-[10px] text-[#c1c6d7]">
          <span className="opacity-50 pointer-events-none font-mono text-[9px]">v1.0.4</span>
          <button
            type="button"
            onClick={() => {
              soundManager.playClickSound();
              if (onQuitApp) onQuitApp();
            }}
            className="hover:text-[#ffb4ab] transition-colors cursor-pointer flex items-center gap-1"
          >
            <span>Quit</span>
            <Power size={10} className="opacity-60" />
          </button>
        </div>
      </footer>
    </div>
  );
};
