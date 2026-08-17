import React, { useState } from 'react';
import { X, Clock, ShieldCheck, Cpu, KeyRound, Activity, Sliders, Check, Copy } from 'lucide-react';
import { QuotaSnapshot } from '../types';
import { soundManager } from '../utils/audio';

interface MetricDetailModalProps {
  snapshot: QuotaSnapshot | null;
  onClose: () => void;
  onUpdateUsage: (id: string, newPrimaryFraction: number, newSecondaryFraction?: number) => void;
}

export const MetricDetailModal: React.FC<MetricDetailModalProps> = ({
  snapshot,
  onClose,
  onUpdateUsage,
}) => {
  const [copied, setCopied] = useState(false);

  if (!snapshot) return null;

  const handleCopyJson = () => {
    navigator.clipboard.writeText(JSON.stringify(snapshot, null, 2));
    soundManager.playClickSound();
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/60 backdrop-blur-sm animate-in fade-in duration-200">
      <div 
        className="w-[340px] max-w-full bg-[#16171b] border border-white/15 rounded-xl shadow-2xl overflow-hidden flex flex-col text-[#e3e2e7] font-['Inter',sans-serif]"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Header */}
        <div className="flex items-center justify-between px-3.5 py-2.5 bg-[#1f2025] border-b border-white/10">
          <div className="flex items-center gap-2">
            <img
              src={snapshot.iconUrl}
              alt={snapshot.displayName}
              className="w-5 h-5 rounded object-cover"
            />
            <div>
              <h3 className="text-[12px] font-semibold text-white leading-tight flex items-center gap-1.5">
                {snapshot.displayName}
                {snapshot.badgeText && (
                  <span className="text-[9px] px-1.5 py-0.5 rounded bg-white/10 text-[#adc6ff] font-normal">
                    {snapshot.badgeText}
                  </span>
                )}
              </h3>
              <p className="text-[10px] text-[#c1c6d7]/70 leading-none mt-0.5">{snapshot.category}</p>
            </div>
          </div>
          <button
            type="button"
            onClick={() => {
              soundManager.playClickSound();
              onClose();
            }}
            className="p-1 rounded-md text-[#c1c6d7] hover:text-white hover:bg-white/10 transition-colors"
          >
            <X size={14} />
          </button>
        </div>

        {/* Content Body */}
        <div className="p-3.5 flex flex-col gap-3 text-[11px] overflow-y-auto max-h-[380px]">
          {/* Status Alert Banner */}
          <div className={`p-2 rounded-lg border flex items-start gap-2 ${
            snapshot.status === 'critical'
              ? 'bg-[#ffb4ab]/10 border-[#ffb4ab]/30 text-[#ffb4ab]'
              : snapshot.status === 'warning'
              ? 'bg-[#ffb874]/10 border-[#ffb874]/30 text-[#ffb874]'
              : 'bg-[#53e16f]/10 border-[#53e16f]/30 text-[#53e16f]'
          }`}>
            <Activity size={14} className="mt-0.5 flex-shrink-0" />
            <div className="text-[10px] leading-tight">
              <span className="font-semibold block">{snapshot.statusText}</span>
              <span className="opacity-80 mt-0.5 block">{snapshot.auxiliaryNotes}</span>
            </div>
          </div>

          {/* Quick Metrics Grid */}
          <div className="grid grid-cols-2 gap-2">
            <div className="bg-black/30 border border-white/5 p-2 rounded-lg">
              <div className="text-[9px] text-[#c1c6d7]/70 flex items-center gap-1">
                <Clock size={10} />
                5H Window Usage
              </div>
              <div className="text-[13px] font-semibold font-mono text-white mt-1">
                {snapshot.row1.usedText || `${(snapshot.row1.primaryFraction * 100).toFixed(0)}%`}
              </div>
              <div className="text-[9px] text-[#adc6ff] mt-0.5">
                {snapshot.row1.resetText || snapshot.resetsInFormatted}
              </div>
            </div>

            <div className="bg-black/30 border border-white/5 p-2 rounded-lg">
              <div className="text-[9px] text-[#c1c6d7]/70 flex items-center gap-1">
                <Cpu size={10} />
                Weekly Velocity
              </div>
              <div className="text-[13px] font-semibold font-mono text-white mt-1">
                {snapshot.row2?.usedText || snapshot.currentUsageFormatted}
              </div>
              <div className="text-[9px] text-[#c1c6d7]/60 mt-0.5">
                {snapshot.row2?.resetText || snapshot.totalLimitFormatted}
              </div>
            </div>
          </div>

          {/* Technical Diagnostics */}
          <div className="bg-black/20 border border-white/5 rounded-lg p-2.5 flex flex-col gap-1.5 text-[10px]">
            <div className="flex justify-between items-center text-[#c1c6d7]">
              <span>Latency & Ping</span>
              <span className="font-mono text-[#53e16f]">{snapshot.latencyMs}ms (HTTP 200 OK)</span>
            </div>
            <div className="flex justify-between items-center text-[#c1c6d7]">
              <span>Auth / CLI Source</span>
              <span className="font-mono text-white truncate max-w-[180px]">{snapshot.cliSource || 'Local Keychain'}</span>
            </div>
            <div className="flex justify-between items-center text-[#c1c6d7]">
              <span>Key Fingerprint</span>
              <span className="font-mono text-white/80">{snapshot.keyMasked || '••••••••••••'}</span>
            </div>
            <div className="flex justify-between items-center text-[#c1c6d7]">
              <span>Plan Tier</span>
              <span className="text-[#adc6ff]">{snapshot.planName || 'Standard'}</span>
            </div>
          </div>

          {/* Live Simulation Slider */}
          <div className="bg-white/[0.03] border border-white/10 rounded-lg p-2.5">
            <div className="flex items-center justify-between text-[10px] text-[#c1c6d7] mb-1.5">
              <span className="flex items-center gap-1">
                <Sliders size={11} className="text-[#adc6ff]" />
                Test Quota Simulation
              </span>
              <span className="font-mono font-bold text-white">
                {(snapshot.row1.primaryFraction * 100).toFixed(0)}%
              </span>
            </div>
            <input
              type="range"
              min="0"
              max="1"
              step="0.05"
              value={snapshot.row1.primaryFraction}
              onChange={(e) => {
                onUpdateUsage(snapshot.id, parseFloat(e.target.value));
              }}
              className="w-full h-1.5 bg-black/40 rounded-lg appearance-none cursor-pointer accent-[#adc6ff]"
            />
            <div className="flex justify-between text-[8px] text-[#c1c6d7]/50 mt-1 font-mono">
              <span>0% (Green)</span>
              <span>70% (Amber)</span>
              <span>90%+ (Critical Red)</span>
            </div>
          </div>
        </div>

        {/* Footer actions */}
        <div className="px-3.5 py-2 bg-[#121317] border-t border-white/10 flex justify-between items-center">
          <button
            type="button"
            onClick={handleCopyJson}
            className="flex items-center gap-1 text-[10px] text-[#c1c6d7] hover:text-white transition-colors"
          >
            {copied ? <Check size={12} className="text-[#53e16f]" /> : <Copy size={12} />}
            <span>{copied ? 'Copied Snapshot' : 'Copy JSON'}</span>
          </button>
          <button
            type="button"
            onClick={() => {
              soundManager.playClickSound();
              onClose();
            }}
            className="px-3 py-1 bg-white/10 hover:bg-white/20 text-white text-[10px] font-medium rounded transition-colors"
          >
            Done
          </button>
        </div>
      </div>
    </div>
  );
};
