import React, { useState } from 'react';
import { 
  X, Key, Sliders, Bell, Laptop, Check, RefreshCw, 
  Terminal, ShieldCheck, Zap, Info, Volume2
} from 'lucide-react';
import { AppSettings } from '../types';
import { soundManager } from '../utils/audio';

interface SettingsModalProps {
  isOpen: boolean;
  settings: AppSettings;
  onClose: () => void;
  onSave: (newSettings: AppSettings) => void;
  onResetAllData: () => void;
}

export const SettingsModal: React.FC<SettingsModalProps> = ({
  isOpen,
  settings,
  onClose,
  onSave,
  onResetAllData,
}) => {
  const [activeTab, setActiveTab] = useState<'keys' | 'limits' | 'appearance' | 'about'>('keys');
  const [formData, setFormData] = useState<AppSettings>(settings);
  const [testingKey, setTestingKey] = useState<string | null>(null);
  const [testResult, setTestResult] = useState<{ [key: string]: 'success' | 'failed' }>({});

  if (!isOpen) return null;

  const handleKeyChange = (keyName: keyof AppSettings['apiKeys'], value: string) => {
    setFormData((prev) => ({
      ...prev,
      apiKeys: {
        ...prev.apiKeys,
        [keyName]: value,
      },
    }));
  };

  const handleTestConnection = (keyName: string) => {
    setTestingKey(keyName);
    soundManager.playRefreshSound();
    setTimeout(() => {
      setTestingKey(null);
      setTestResult((prev) => ({ ...prev, [keyName]: 'success' }));
    }, 600);
  };

  const handleSaveAndClose = () => {
    soundManager.playClickSound();
    onSave(formData);
    onClose();
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/70 backdrop-blur-md animate-in fade-in duration-200">
      <div 
        className="w-[420px] max-w-full bg-[#16171b] border border-white/15 rounded-xl shadow-2xl overflow-hidden flex flex-col text-[#e3e2e7] font-['Inter',sans-serif]"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Modal Header */}
        <div className="flex items-center justify-between px-4 py-3 bg-[#1e1f24] border-b border-white/10">
          <div className="flex items-center gap-2">
            <div className="w-5 h-5 rounded bg-[#adc6ff]/20 flex items-center justify-center text-[#adc6ff]">
              <Sliders size={13} />
            </div>
            <div>
              <h2 className="text-[13px] font-semibold text-white">QuotaBar Preferences</h2>
              <p className="text-[10px] text-[#c1c6d7]/70">Unified Multi-Vendor AI Quota Observability</p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="p-1 rounded-md text-[#c1c6d7] hover:text-white hover:bg-white/10 transition-colors"
          >
            <X size={14} />
          </button>
        </div>

        {/* Tab Navigation */}
        <div className="flex items-center px-4 pt-2 border-b border-white/10 bg-[#191a1f] gap-2">
          <button
            type="button"
            onClick={() => setActiveTab('keys')}
            className={`flex items-center gap-1.5 px-2.5 py-1.5 text-[11px] font-medium border-b-2 transition-all ${
              activeTab === 'keys'
                ? 'border-[#adc6ff] text-[#adc6ff]'
                : 'border-transparent text-[#c1c6d7] hover:text-white'
            }`}
          >
            <Key size={12} />
            API & Tokens
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('limits')}
            className={`flex items-center gap-1.5 px-2.5 py-1.5 text-[11px] font-medium border-b-2 transition-all ${
              activeTab === 'limits'
                ? 'border-[#adc6ff] text-[#adc6ff]'
                : 'border-transparent text-[#c1c6d7] hover:text-white'
            }`}
          >
            <Bell size={12} />
            Polling & Alerts
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('appearance')}
            className={`flex items-center gap-1.5 px-2.5 py-1.5 text-[11px] font-medium border-b-2 transition-all ${
              activeTab === 'appearance'
                ? 'border-[#adc6ff] text-[#adc6ff]'
                : 'border-transparent text-[#c1c6d7] hover:text-white'
            }`}
          >
            <Laptop size={12} />
            Menu Bar
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('about')}
            className={`flex items-center gap-1.5 px-2.5 py-1.5 text-[11px] font-medium border-b-2 transition-all ${
              activeTab === 'about'
                ? 'border-[#adc6ff] text-[#adc6ff]'
                : 'border-transparent text-[#c1c6d7] hover:text-white'
            }`}
          >
            <Info size={12} />
            Architecture
          </button>
        </div>

        {/* Tab Contents */}
        <div className="p-4 flex flex-col gap-3.5 text-[11px] max-h-[360px] overflow-y-auto">
          {/* TAB 1: API & Tokens */}
          {activeTab === 'keys' && (
            <div className="flex flex-col gap-3">
              {/* CLI Auto-discovery Notice */}
              <div className="p-2.5 rounded-lg bg-[#adc6ff]/10 border border-[#adc6ff]/20 flex items-start gap-2">
                <Terminal size={14} className="text-[#adc6ff] mt-0.5 flex-shrink-0" />
                <div className="text-[10px] text-[#adc6ff]/90 leading-tight">
                  <span className="font-semibold block text-[#adc6ff]">macOS Local CLI Token Auto-Discovery</span>
                  QuotaBar scans local CLI authentications (e.g. <code className="font-mono bg-black/30 px-1 py-0.5 rounded">~/.claude.json</code>, <code className="font-mono bg-black/30 px-1 py-0.5 rounded">gh auth token</code>, <code className="font-mono bg-black/30 px-1 py-0.5 rounded">~/.config/github-copilot</code>) to monitor quotas without manual key entry.
                </div>
              </div>

              {/* Provider Key Fields */}
              <div className="flex flex-col gap-2.5">
                {/* Claude Key */}
                <div>
                  <div className="flex justify-between items-center mb-1">
                    <label className="text-[10px] font-medium text-white flex items-center gap-1">
                      <span>Anthropic Claude API Key / OAuth</span>
                      <span className="text-[9px] text-[#53e16f] font-normal">• Discovered via CLI</span>
                    </label>
                    <button
                      type="button"
                      onClick={() => handleTestConnection('claude')}
                      className="text-[9px] text-[#adc6ff] hover:underline flex items-center gap-1"
                    >
                      {testingKey === 'claude' ? <RefreshCw size={9} className="animate-spin" /> : testResult['claude'] ? <Check size={9} className="text-[#53e16f]" /> : null}
                      Test Ping
                    </button>
                  </div>
                  <input
                    type="password"
                    placeholder="Auto-discovered: ~/.claude.json (or enter sk-ant-...)"
                    value={formData.apiKeys.claudeKey}
                    onChange={(e) => handleKeyChange('claudeKey', e.target.value)}
                    className="w-full px-2.5 py-1.5 bg-black/40 border border-white/10 rounded text-[10px] text-white focus:outline-none focus:border-[#adc6ff] font-mono"
                  />
                </div>

                {/* Gemini AI Studio */}
                <div>
                  <div className="flex justify-between items-center mb-1">
                    <label className="text-[10px] font-medium text-white flex items-center gap-1">
                      <span>Google AI Studio / Gemini Key</span>
                      <span className="text-[9px] text-[#53e16f] font-normal">• Auto-connected</span>
                    </label>
                    <button
                      type="button"
                      onClick={() => handleTestConnection('gemini')}
                      className="text-[9px] text-[#adc6ff] hover:underline flex items-center gap-1"
                    >
                      {testingKey === 'gemini' ? <RefreshCw size={9} className="animate-spin" /> : testResult['gemini'] ? <Check size={9} className="text-[#53e16f]" /> : null}
                      Test Ping
                    </button>
                  </div>
                  <input
                    type="password"
                    placeholder="AIzaSy... (AI Studio Tier 1 / Cloud Billing)"
                    value={formData.apiKeys.geminiKey}
                    onChange={(e) => handleKeyChange('geminiKey', e.target.value)}
                    className="w-full px-2.5 py-1.5 bg-black/40 border border-white/10 rounded text-[10px] text-white focus:outline-none focus:border-[#adc6ff] font-mono"
                  />
                </div>

                {/* OpenRouter */}
                <div>
                  <div className="flex justify-between items-center mb-1">
                    <label className="text-[10px] font-medium text-white">OpenRouter API Key (GET /api/v1/auth/key)</label>
                    <button
                      type="button"
                      onClick={() => handleTestConnection('openrouter')}
                      className="text-[9px] text-[#adc6ff] hover:underline flex items-center gap-1"
                    >
                      {testingKey === 'openrouter' ? <RefreshCw size={9} className="animate-spin" /> : testResult['openrouter'] ? <Check size={9} className="text-[#53e16f]" /> : null}
                      Test Ping
                    </button>
                  </div>
                  <input
                    type="password"
                    placeholder="sk-or-v1-... ($20.00 cap / $14.20 left)"
                    value={formData.apiKeys.openRouterKey}
                    onChange={(e) => handleKeyChange('openRouterKey', e.target.value)}
                    className="w-full px-2.5 py-1.5 bg-black/40 border border-white/10 rounded text-[10px] text-white focus:outline-none focus:border-[#adc6ff] font-mono"
                  />
                </div>

                {/* GitHub PAT */}
                <div>
                  <div className="flex justify-between items-center mb-1">
                    <label className="text-[10px] font-medium text-white flex items-center gap-1">
                      <span>GitHub Personal Access Token (REST / GraphQL)</span>
                      <span className="text-[9px] text-[#53e16f] font-normal">• gh CLI</span>
                    </label>
                    <button
                      type="button"
                      onClick={() => handleTestConnection('github')}
                      className="text-[9px] text-[#adc6ff] hover:underline flex items-center gap-1"
                    >
                      {testingKey === 'github' ? <RefreshCw size={9} className="animate-spin" /> : testResult['github'] ? <Check size={9} className="text-[#53e16f]" /> : null}
                      Test Ping
                    </button>
                  </div>
                  <input
                    type="password"
                    placeholder="ghp_... (Rate limit: 5,000 req/hr)"
                    value={formData.apiKeys.githubPat}
                    onChange={(e) => handleKeyChange('githubPat', e.target.value)}
                    className="w-full px-2.5 py-1.5 bg-black/40 border border-white/10 rounded text-[10px] text-white focus:outline-none focus:border-[#adc6ff] font-mono"
                  />
                </div>
              </div>
            </div>
          )}

          {/* TAB 2: Polling & Alerts */}
          {activeTab === 'limits' && (
            <div className="flex flex-col gap-3.5">
              {/* Background Polling Interval */}
              <div>
                <label className="text-[10px] font-medium text-white block mb-1.5">
                  Background Polling Cadence (Power-Aware Timer)
                </label>
                <div className="grid grid-cols-4 gap-1.5">
                  {[30, 60, 120, 300].map((sec) => (
                    <button
                      key={sec}
                      type="button"
                      onClick={() => setFormData((prev) => ({ ...prev, refreshIntervalSeconds: sec }))}
                      className={`py-1.5 rounded text-[10px] font-medium border transition-all ${
                        formData.refreshIntervalSeconds === sec
                          ? 'bg-[#adc6ff]/20 border-[#adc6ff] text-white'
                          : 'bg-black/30 border-white/10 text-[#c1c6d7] hover:bg-white/5'
                      }`}
                    >
                      {sec < 60 ? `${sec}s` : `${sec / 60}m`}
                    </button>
                  ))}
                </div>
              </div>

              {/* Threshold Sliders */}
              <div className="flex flex-col gap-2 bg-black/20 p-2.5 rounded-lg border border-white/5">
                <div>
                  <div className="flex justify-between text-[10px] text-white mb-1">
                    <span className="text-[#ffb874]">Warning Threshold (Amber)</span>
                    <span className="font-mono font-semibold">{formData.warningThreshold}%</span>
                  </div>
                  <input
                    type="range"
                    min="50"
                    max="85"
                    value={formData.warningThreshold}
                    onChange={(e) => setFormData((prev) => ({ ...prev, warningThreshold: parseInt(e.target.value) }))}
                    className="w-full h-1 bg-black/40 rounded-lg appearance-none cursor-pointer accent-[#ffb874]"
                  />
                </div>

                <div>
                  <div className="flex justify-between text-[10px] text-white mb-1">
                    <span className="text-[#ffb4ab]">Critical Threshold (Red & Glow)</span>
                    <span className="font-mono font-semibold">{formData.criticalThreshold}%</span>
                  </div>
                  <input
                    type="range"
                    min="80"
                    max="99"
                    value={formData.criticalThreshold}
                    onChange={(e) => setFormData((prev) => ({ ...prev, criticalThreshold: parseInt(e.target.value) }))}
                    className="w-full h-1 bg-black/40 rounded-lg appearance-none cursor-pointer accent-[#ffb4ab]"
                  />
                </div>
              </div>

              {/* Toggles */}
              <div className="flex flex-col gap-2">
                <label className="flex items-center justify-between p-2 rounded bg-black/20 border border-white/5 cursor-pointer">
                  <span className="text-[10px] text-white flex items-center gap-1.5">
                    <Volume2 size={13} className="text-[#c1c6d7]" />
                    Haptic & Subtle Audio Feedback
                  </span>
                  <input
                    type="checkbox"
                    checked={formData.hapticFeedback}
                    onChange={(e) => setFormData((prev) => ({ ...prev, hapticFeedback: e.target.checked }))}
                    className="rounded bg-black/40 border-white/20 text-[#adc6ff] focus:ring-0"
                  />
                </label>

                <label className="flex items-center justify-between p-2 rounded bg-black/20 border border-white/5 cursor-pointer">
                  <span className="text-[10px] text-white flex items-center gap-1.5">
                    <Zap size={13} className="text-[#c1c6d7]" />
                    Launch Automatically at Login
                  </span>
                  <input
                    type="checkbox"
                    checked={formData.launchAtLogin}
                    onChange={(e) => setFormData((prev) => ({ ...prev, launchAtLogin: e.target.checked }))}
                    className="rounded bg-black/40 border-white/20 text-[#adc6ff] focus:ring-0"
                  />
                </label>
              </div>
            </div>
          )}

          {/* TAB 3: Menu Bar Appearance */}
          {activeTab === 'appearance' && (
            <div className="flex flex-col gap-3">
              <div>
                <label className="text-[10px] font-medium text-white block mb-1.5">
                  Menu Bar Status Item Mode
                </label>
                <div className="grid grid-cols-3 gap-2">
                  <button
                    type="button"
                    onClick={() => setFormData((prev) => ({ ...prev, menuBarMode: 'gauge' }))}
                    className={`p-2 rounded text-left border transition-all ${
                      formData.menuBarMode === 'gauge'
                        ? 'bg-[#adc6ff]/20 border-[#adc6ff] text-white'
                        : 'bg-black/30 border-white/10 text-[#c1c6d7] hover:bg-white/5'
                    }`}
                  >
                    <div className="text-[11px] font-medium">Gauge Icon</div>
                    <div className="text-[9px] opacity-70 mt-0.5">Gauge + dynamic status dot</div>
                  </button>

                  <button
                    type="button"
                    onClick={() => setFormData((prev) => ({ ...prev, menuBarMode: 'percentage' }))}
                    className={`p-2 rounded text-left border transition-all ${
                      formData.menuBarMode === 'percentage'
                        ? 'bg-[#adc6ff]/20 border-[#adc6ff] text-white'
                        : 'bg-black/30 border-white/10 text-[#c1c6d7] hover:bg-white/5'
                    }`}
                  >
                    <div className="text-[11px] font-medium">Worst-Case %</div>
                    <div className="text-[9px] opacity-70 mt-0.5">Shows e.g. "98% GH"</div>
                  </button>

                  <button
                    type="button"
                    onClick={() => setFormData((prev) => ({ ...prev, menuBarMode: 'compact' }))}
                    className={`p-2 rounded text-left border transition-all ${
                      formData.menuBarMode === 'compact'
                        ? 'bg-[#adc6ff]/20 border-[#adc6ff] text-white'
                        : 'bg-black/30 border-white/10 text-[#c1c6d7] hover:bg-white/5'
                    }`}
                  >
                    <div className="text-[11px] font-medium">Minimal Dot</div>
                    <div className="text-[9px] opacity-70 mt-0.5">Ultra-compact 6px dot</div>
                  </button>
                </div>
              </div>

              {/* Data Reset */}
              <div className="p-3 bg-red-500/10 border border-red-500/20 rounded-lg">
                <h4 className="text-[11px] font-medium text-[#ffb4ab]">Reset Quota Telemetry</h4>
                <p className="text-[9px] text-[#c1c6d7]/80 mt-0.5">
                  Restore all 7 provider quotas to baseline reference values.
                </p>
                <button
                  type="button"
                  onClick={() => {
                    onResetAllData();
                    soundManager.playAlertSound();
                  }}
                  className="mt-2 px-2.5 py-1 bg-red-500/20 hover:bg-red-500/30 text-[#ffb4ab] rounded text-[10px] font-medium transition-colors"
                >
                  Reset Snapshots
                </button>
              </div>
            </div>
          )}

          {/* TAB 4: Architecture */}
          {activeTab === 'about' && (
            <div className="flex flex-col gap-2.5 text-[10px] text-[#c1c6d7] leading-relaxed">
              <div className="p-2.5 rounded-lg bg-black/40 border border-white/5 flex items-center gap-3">
                <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-[#adc6ff] to-[#4b8eff] flex items-center justify-center text-black font-bold text-sm">
                  Q
                </div>
                <div>
                  <div className="text-white font-semibold text-[11px]">QuotaBar for macOS</div>
                  <div className="text-[9px] opacity-70">Version 1.0.4 (Build 2026.08)</div>
                </div>
              </div>

              <div className="space-y-1.5">
                <p>
                  <strong className="text-white">Zero-Scroll Guarantee:</strong> Fixed 340pt x 410pt geometry strictly fitting all 7 providers and 3 categories in a consolidated single-glance layout.
                </p>
                <p>
                  <strong className="text-white">Parallel Concurrency:</strong> Swift TaskGroup actor architecture with strict 4.0s timeout guards and Stale-While-Revalidate caching.
                </p>
                <p>
                  <strong className="text-white">Footprint:</strong> Native Swift 6 + SwiftUI runtime engine (&lt;25MB memory, 0.0% idle CPU).
                </p>
              </div>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="px-4 py-2.5 bg-[#121317] border-t border-white/10 flex justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="px-3 py-1 bg-white/5 hover:bg-white/10 text-[#c1c6d7] text-[10px] font-medium rounded transition-colors"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleSaveAndClose}
            className="px-3 py-1 bg-[#adc6ff] hover:bg-[#d8e2ff] text-black text-[10px] font-semibold rounded transition-colors"
          >
            Save Changes
          </button>
        </div>
      </div>
    </div>
  );
};
