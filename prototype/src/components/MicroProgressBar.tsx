import React from 'react';
import { DualBarMetrics } from '../types';

interface MicroProgressBarProps {
  metrics: DualBarMetrics;
  isCritical?: boolean;
  accentColor?: string;
  className?: string;
}

export const MicroProgressBar: React.FC<MicroProgressBarProps> = ({
  metrics,
  isCritical = false,
  accentColor,
  className = '',
}) => {
  const { primaryFraction, secondaryFraction = 0, label, statusColor } = metrics;

  const primaryPct = Math.max(0, Math.min(100, primaryFraction * 100));
  const secondaryPct = Math.max(0, Math.min(100 - primaryPct, secondaryFraction * 100));

  // Determine track styling & glows
  const hasGlow = isCritical || primaryPct >= 90;
  
  // Background track color
  const trackBgClass = isCritical 
    ? 'bg-[#ffb4ab]/25 shadow-[0_0_6px_rgba(255,180,171,0.5)]'
    : 'bg-white/[0.08]';

  // Bar colors
  const primaryBarColor = statusColor || accentColor || '#53e16f';

  return (
    <div className={`flex items-center gap-2 group/bar ${className}`}>
      <div 
        className={`w-full h-[3.5px] rounded-full overflow-hidden flex relative transition-all duration-300 ${trackBgClass}`}
        title={`${primaryPct.toFixed(0)}% used`}
      >
        {/* Primary segment */}
        <div
          className="h-full rounded-full transition-all duration-500 ease-out"
          style={{
            width: `${primaryPct}%`,
            backgroundColor: primaryBarColor,
          }}
        />

        {/* Secondary segment (e.g. warning buffer or burst allocation) */}
        {secondaryPct > 0 && (
          <div
            className="h-full rounded-full opacity-60 transition-all duration-500 ease-out"
            style={{
              width: `${secondaryPct}%`,
              backgroundColor: isCritical ? '#ffb4ab' : '#53e16f',
            }}
          />
        )}
      </div>

      {/* Label (e.g. 5H, WK) */}
      <span
        className={`text-[9px] font-mono leading-[12px] w-4 text-right flex-shrink-0 transition-colors select-none ${
          hasGlow ? 'text-[#ffb4ab] font-semibold' : 'text-[#c1c6d7]/70 group-hover/bar:text-[#e3e2e7]'
        }`}
      >
        {label}
      </span>
    </div>
  );
};
