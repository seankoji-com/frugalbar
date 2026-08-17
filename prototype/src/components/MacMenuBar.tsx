import React, { useState, useEffect } from 'react';
import { 
  Wifi, Battery, Search, SlidersHorizontal, Gauge, 
  Command, Eye, Sparkles, RefreshCw, Layers
} from 'lucide-react';
import { ProviderStatus, AppSettings } from '../types';
import { soundManager } from '../utils/audio';

interface MacMenuBarProps {
  overallStatus: ProviderStatus;
  worstUsagePercentage: number;
  isPopoverOpen: boolean;
  settings: AppSettings;
  onTogglePopover: () => void;
  onRefreshAll: () => void;
}

export const MacMenuBar: React.FC<MacMenuBarProps> = ({
  overallStatus,
  worstUsagePercentage,
  isPopoverOpen,
  settings,
  onTogglePopover,
  onRefreshAll,
}) => {
  const [timeString, setTimeString] = useState('');

  useEffect(() => {
    const updateTime = () => {
      const now = new Date();
      setTimeString(
        now.toLocaleDateString('en-US', {
          weekday: 'short',
          month: 'short',
          day: 'numeric',
          hour: 'numeric',
          minute: '2-digit',
        })
      );
    };
    updateTime();
    const interval = setInterval(updateTime, 10000);
    return () => clearInterval(interval);
  }, []);

  const handleStatusItemClick = (e: React.MouseEvent) => {
    e.stopPropagation();
    soundManager.playClickSound();
    onTogglePopover();
  };

  // Status dot color & animation
  const getStatusDot = () => {
    if (overallStatus === 'critical') {
      return (
        <span className="w-1.5 h-1.5 rounded-full bg-[#ffb4ab] shadow-[0_0_6px_rgba(255,180,171,0.9)] animate-pulse" />
      );
    }
    if (overallStatus === 'warning') {
      return (
        <span className="w-1.5 h-1.5 rounded-full bg-[#ffb874] shadow-[0_0_4px_rgba(255,184,116,0.8)]" />
      );
    }
    return (
      <span className="w-1.5 h-1.5 rounded-full bg-[#53e16f] shadow-[0_0_4px_rgba(83,225,111,0.8)]" />
    );
  };

  return (
    <div className="w-full h-7 bg-black/40 backdrop-blur-2xl border-b border-white/10 px-3 flex items-center justify-between text-white/90 text-[12px] font-[-apple-system,BlinkMacSystemFont,'Inter',sans-serif] select-none z-40 relative">
      {/* Left Menu Items */}
      <div className="flex items-center gap-4">
        <span className="font-semibold text-sm cursor-default hover:text-white transition-colors"></span>
        <span className="font-semibold text-[12px] text-white cursor-default">QuotaBar</span>
        <div className="hidden sm:flex items-center gap-3 text-white/70 text-[12px]">
          <span className="hover:text-white cursor-pointer transition-colors">File</span>
          <span className="hover:text-white cursor-pointer transition-colors">Edit</span>
          <span className="hover:text-white cursor-pointer transition-colors">View</span>
          <span className="hover:text-white cursor-pointer transition-colors">Window</span>
          <span className="hover:text-white cursor-pointer transition-colors">Help</span>
        </div>
      </div>

      {/* Right Menu Items & NSStatusItem */}
      <div className="flex items-center gap-3">
        {/* Dynamic QuotaBar NSStatusItem */}
        <button
          type="button"
          id="quotabar-menu-bar-status-item"
          onClick={handleStatusItemClick}
          aria-label="Toggle QuotaBar popover"
          className={`flex items-center gap-1.5 px-2 py-0.5 rounded transition-all cursor-pointer ${
            isPopoverOpen
              ? 'bg-white/20 text-white shadow-sm ring-1 ring-white/20'
              : 'hover:bg-white/10 text-white/90 active:bg-white/15'
          }`}
        >
          {/* Gauge Icon */}
          <Gauge size={13} className="opacity-90" />

          {/* Status Mode Readout */}
          {settings.menuBarMode === 'percentage' ? (
            <span className="font-mono text-[10px] font-semibold text-white/90 flex items-center gap-1">
              {getStatusDot()}
              {worstUsagePercentage}%
            </span>
          ) : (
            getStatusDot()
          )}
        </button>

        {/* System Tray Icons */}
        <div className="flex items-center gap-2.5 text-white/80">
          <Wifi size={13} className="opacity-80" />
          <Battery size={14} className="opacity-80" />
          <Search size={12} className="opacity-75" />
          <SlidersHorizontal size={12} className="opacity-75" />
          <span className="text-[11px] text-white/80 font-medium pl-1">{timeString || 'Mon Aug 17 4:46 PM'}</span>
        </div>
      </div>
    </div>
  );
};
