import React, { useState } from 'react';
import { QuotaSnapshot } from '../types';
import { MicroProgressBar } from './MicroProgressBar';
import { soundManager } from '../utils/audio';

interface MetricRowViewProps {
  snapshot: QuotaSnapshot;
  isGrayscale?: boolean;
  onSelect: (snapshot: QuotaSnapshot) => void;
}

export const MetricRowView: React.FC<MetricRowViewProps> = ({
  snapshot,
  isGrayscale = false,
  onSelect,
}) => {
  const [imgError, setImgError] = useState(false);

  const isCritical = snapshot.status === 'critical';
  const isWarning = snapshot.status === 'warning';

  const handleClick = () => {
    soundManager.playClickSound();
    onSelect(snapshot);
  };

  return (
    <div
      onClick={handleClick}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => e.key === 'Enter' && handleClick()}
      title={`${snapshot.displayName} • ${snapshot.statusText} (Click to inspect)`}
      className="flex items-center gap-3 px-1.5 py-1 rounded-md hover:bg-white/[0.06] active:bg-white/[0.09] transition-all -mx-1 cursor-pointer group select-none relative"
    >
      {/* Provider Avatar / Icon */}
      <div className="relative w-5 h-5 flex-shrink-0 flex items-center justify-center">
        {!imgError ? (
          <img
            src={snapshot.iconUrl}
            alt={snapshot.displayName}
            onError={() => setImgError(true)}
            className={`w-5 h-5 rounded object-cover flex-shrink-0 opacity-85 group-hover:opacity-100 transition-opacity ${
              isGrayscale ? 'grayscale' : ''
            }`}
          />
        ) : (
          <div
            className="w-5 h-5 rounded flex items-center justify-center text-[10px] font-bold text-white uppercase shadow-inner"
            style={{ backgroundColor: snapshot.accentColor }}
          >
            {snapshot.displayName.charAt(0)}
          </div>
        )}

        {/* Status indicator badge dot */}
        {isCritical && (
          <span className="absolute -top-0.5 -right-0.5 w-1.5 h-1.5 rounded-full bg-[#ffb4ab] ring-1 ring-[#121317] animate-pulse" />
        )}
        {isWarning && !isCritical && (
          <span className="absolute -top-0.5 -right-0.5 w-1.5 h-1.5 rounded-full bg-[#ffb874] ring-1 ring-[#121317]" />
        )}
      </div>

      {/* Dual Progress Bars */}
      <div className="flex-1 flex flex-col gap-[3px] min-w-0">
        <MicroProgressBar
          metrics={snapshot.row1}
          isCritical={isCritical}
          accentColor={snapshot.accentColor}
        />
        {snapshot.row2 && (
          <MicroProgressBar
            metrics={snapshot.row2}
            isCritical={isCritical}
            accentColor={snapshot.accentColor}
          />
        )}
      </div>
    </div>
  );
};
