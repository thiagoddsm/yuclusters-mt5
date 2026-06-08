import React, { useState, useEffect, useCallback } from 'react';
import { useWebSocket } from './useWebSocket';
import FootprintCanvas from './FootprintCanvas';
import AlertEngine from './utils/AlertEngine';

const BACKEND_PORT = 6002;
const WS_URL = `ws://localhost:${BACKEND_PORT}/ws`;
const API_URL = `http://localhost:${BACKEND_PORT}`;

export default function App() {
  const [history, setHistory] = useState([]);
  const [activeCluster, setActiveCluster] = useState(null);
  const [lastTickTime, setLastTickTime] = useState(null);
  const [lastBid, setLastBid] = useState(0);
  const [lastAsk, setLastAsk] = useState(0);

  // Phase 2 & 4 Settings
  const [stepMultiplier, setStepMultiplier] = useState(75);
  const [viewMode, setViewMode] = useState('bidask'); // 'bidask' or 'delta'
  const [imbalanceRatio, setImbalanceRatio] = useState(300); // percentage

  // Cluster aggregator config
  const [closeMode, setCloseMode] = useState('delta');
  const [deltaMax, setDeltaMax] = useState(800);
  const [volumeMax, setVolumeMax] = useState(1000);
  const [timeSeconds, setTimeSeconds] = useState(300);
  const [rangePoints, setRangePoints] = useState(10);
  const [configDirty, setConfigDirty] = useState(false);
  const [targetSymbol, setTargetSymbol] = useState('EURUSD');

  // History Mode
  const [historicalDate, setHistoricalDate] = useState('');
  const [isLoadingHistory, setIsLoadingHistory] = useState(false);

  // WebSocket Data States (Phase 5)
  const [domData, setDomData] = useState(null);
  const [bigTrades, setBigTrades] = useState([]);

  // Chart toolbar
  const [showChartSettings, setShowChartSettings] = useState(false);
  const [centerTrigger, setCenterTrigger] = useState(0);
  
  // Toasts
  const [toasts, setToasts] = useState([]);
  
  const pushToast = useCallback((msg, type = 'info') => {
    const id = Date.now() + Math.random();
    setToasts(prev => [...prev, { id, msg, type }]);
    setTimeout(() => {
      setToasts(prev => prev.filter(t => t.id !== id));
    }, 5000);
  }, []);

  // Fetch config from backend on load
  const fetchConfig = useCallback(async () => {
    try {
      const res = await fetch(`${API_URL}/config`);
      if (res.ok) {
        const data = await res.json();
        setCloseMode(data.close_mode || 'delta');
        setDeltaMax(data.delta_max || 800);
        setVolumeMax(data.volume_max || 1000);
        setTimeSeconds(data.time_seconds || 300);
        setRangePoints(data.range_points || 10);
        if (data.symbol) setTargetSymbol(data.symbol);
      }
    } catch (e) {}
  }, []);

  // Push config update to backend
  const applyConfig = useCallback(async (mode, delta, vol, time, range) => {
    try {
      await fetch(`${API_URL}/config`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ close_mode: mode, delta_max: delta, volume_max: vol, time_seconds: time, range_points: range }),
      });
      setConfigDirty(false);
    } catch (e) {}
  }, []);

  // Fetch initial history when backend becomes reachable
  const fetchHistory = useCallback(async () => {
    try {
      const res = await fetch(`${API_URL}/history`);
      if (res.ok) {
        const data = await res.json();
        setHistory(data);
      }
    } catch (e) {
      console.warn("Could not fetch cluster history:", e);
    }
  }, []);

  // Message Handler for WebSocket
  const handleWebSocketMessage = useCallback((msg) => {
    setLastTickTime(new Date());
    
    if (msg.type === 'init') {
      setActiveCluster(msg.active);
      fetchHistory();
    } else if (msg.type === 'reset') {
      setHistory([]);
      setActiveCluster(null);
    } else if (msg.type === 'history_ready') {
      fetchHistory();
    } else if (msg.type === 'tick') {
      setActiveCluster(msg.active);
      if (msg.active?.bid) setLastBid(msg.active.bid);
      if (msg.active?.ask) setLastAsk(msg.active.ask);
      // If a cluster has just closed, we receive the closed state
      if (msg.closed) {
        setHistory(prev => {
          const updated = [...prev, msg.closed];
          if (updated.length > 500) {
            updated.shift();
          }
          return updated;
        });
        
        // Dispatch alerts for the newly closed cluster
        AlertEngine.processClusters([msg.closed], pushToast);
      }
      
      if (msg.dom) {
        setDomData(msg.dom);
      }
    } else if (msg.type === 'big_trade') {
      setBigTrades(prev => [...prev.slice(-49), msg.data]); // Keep last 50
      pushToast(`BIG TRADE: ${msg.data.is_buy ? 'BUY' : 'SELL'} ${msg.data.volume} @ ${msg.data.price}`, msg.data.is_buy ? 'info' : 'warning');
      AlertEngine.processBigTrade(msg.data);
    }
  }, [fetchHistory, pushToast]);

  const wsStatus = useWebSocket(WS_URL, handleWebSocketMessage);

  useEffect(() => {
    fetchHistory();
    fetchConfig();
  }, [fetchHistory, fetchConfig, wsStatus]);

  // Aggregate stats from history
  const totalVolume = history.reduce((acc, c) => acc + (c.total_volume || 0), 0) + (activeCluster?.total_volume || 0);
  const loadHistory = async (dateStr) => {
    setIsLoadingHistory(true);
    try {
      const start = new Date(dateStr);
      start.setHours(0, 0, 0, 0);
      const end = new Date(dateStr);
      end.setHours(23, 59, 59, 999);
      
      await fetch(`${API_URL}/history/load`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ start_time: start.toISOString(), end_time: end.toISOString() })
      });
      setHistoricalDate(dateStr);
    } catch (e) {
      console.error(e);
      pushToast('Error loading history', 'error');
    }
    setIsLoadingHistory(false);
  };

  const returnToLive = async () => {
    setIsLoadingHistory(true);
    try {
      await fetch(`${API_URL}/history/live`, { method: 'POST' });
      setHistoricalDate('');
    } catch (e) {}
    setIsLoadingHistory(false);
  };

  const avgVolumePerCluster = history.length > 0 ? (history.reduce((acc, c) => acc + (c.total_volume || 0), 0) / history.length).toFixed(0) : 0;
  
  const allClusters = [...history];
  if (activeCluster) allClusters.push(activeCluster);

  // Use tick_size from the latest cluster data (set by MT5 backend)
  const dynamicTickSize = allClusters.length > 0 ? (allClusters[allClusters.length - 1].tick_size || 0.01) : 0.01;

  return (
    <div className="flex flex-col h-full bg-[#0B0E14] text-slate-100 relative">
      {/* Toast Container */}
      <div className="absolute top-4 right-4 z-50 flex flex-col gap-2">
        {toasts.map(t => (
          <div key={t.id} className={`px-4 py-3 rounded-md shadow-lg font-medium text-sm flex items-center gap-2 border ${
            t.type === 'error' ? 'bg-red-500/10 border-red-500 text-red-500' :
            t.type === 'warning' ? 'bg-amber-500/10 border-amber-500 text-amber-400' :
            'bg-blue-500/10 border-blue-500 text-blue-400'
          }`}>
            <span>{t.type === 'error' ? '🚨' : t.type === 'warning' ? '⚠️' : 'ℹ️'}</span>
            {t.msg}
          </div>
        ))}
      </div>

      {/* Premium Header */}
      <header className="flex items-center justify-between px-6 py-4 bg-[#151B26] border-b border-slate-800 shadow-md relative z-10">
        <div className="flex items-center gap-3">
          <div className="w-9 h-9 bg-gradient-to-tr from-[#00E676] to-[#00B0FF] rounded-lg flex items-center justify-center font-bold text-lg text-white shadow-lg">
            Yu
          </div>
          <div>
            <h1 className="text-lg font-bold tracking-tight bg-gradient-to-r from-white to-slate-400 bg-clip-text text-transparent">
              YuClusters Local
            </h1>
            <p className="text-xs text-slate-400">Order Flow Footprint Analyzer 2.0</p>
          </div>
        </div>
        
        {/* Connection Status & History indicator */}
        <div className="flex items-center gap-6 text-sm">
          <div className="flex items-center gap-2 mr-4 bg-[#0B0E14] border border-slate-800 p-1 rounded-lg">
            <input 
              type="date" 
              value={historicalDate}
              onChange={(e) => loadHistory(e.target.value)}
              className="bg-transparent text-slate-300 text-xs px-2 py-1 outline-none cursor-pointer"
              title="Load Historical Date"
            />
            {historicalDate && (
              <button 
                onClick={returnToLive}
                className="bg-[#FF4081] text-white text-[10px] font-bold px-2 py-1 rounded hover:bg-[#F50057] transition-colors"
              >
                LIVE
              </button>
            )}
          </div>

          {lastTickTime && (
            <div className="text-slate-400 text-xs hidden sm:block">
              Last Update: <span className="font-mono text-slate-300">{lastTickTime.toLocaleTimeString()}</span>
            </div>
          )}
          
          <div className="flex items-center gap-2">
            <span className="text-xs text-slate-400 font-medium">MT5 Bridge:</span>
            <div className={`flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-semibold ${
              wsStatus === 'connected' 
                ? 'bg-[#00E676]/10 text-[#00E676] border border-[#00E676]/20' 
                : wsStatus === 'connecting'
                ? 'bg-amber-500/10 text-amber-500 border border-amber-500/20'
                : 'bg-red-500/10 text-red-500 border border-red-500/20'
            }`}>
              <span className={`w-1.5 h-1.5 rounded-full ${
                wsStatus === 'connected' ? 'bg-[#00E676] animate-pulse' : wsStatus === 'connecting' ? 'bg-amber-500 animate-pulse' : 'bg-red-500'
              }`} />
              {wsStatus.toUpperCase()}
            </div>
          </div>
        </div>
      </header>

      {/* Main Body Layout */}
      <main className="flex-1 flex overflow-hidden p-6 gap-6">
        {/* Footprint Chart Panel */}
        <div className="flex-1 flex flex-col h-full bg-[#151B26]/30 rounded-xl overflow-hidden relative">
          
          {isLoadingHistory && (
            <div className="absolute inset-0 bg-[#0B0E14]/80 backdrop-blur-sm flex items-center justify-center z-50">
              <div className="flex flex-col items-center">
                <div className="w-10 h-10 border-4 border-[#00B0FF] border-t-transparent rounded-full animate-spin"></div>
                <span className="mt-4 text-[#00B0FF] font-bold text-sm tracking-widest uppercase">Fetching History...</span>
              </div>
            </div>
          )}

          {/* Chart Toolbar */}
          <div className="absolute top-2 left-2 z-20 flex items-center gap-1 bg-[#0B0E14]/90 border border-slate-700 rounded-lg px-1.5 py-1">
            {/* Align to current price */}
            <button
              onClick={() => setCenterTrigger(t => t + 1)}
              title="Alinhar ao preço atual"
              className="w-7 h-7 flex items-center justify-center text-slate-400 hover:text-[#00E676] hover:bg-slate-800 rounded transition"
            >
              <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
                <circle cx="12" cy="12" r="3"/>
                <line x1="12" y1="2" x2="12" y2="6"/>
                <line x1="12" y1="18" x2="12" y2="22"/>
                <line x1="2" y1="12" x2="6" y2="12"/>
                <line x1="18" y1="12" x2="22" y2="12"/>
              </svg>
            </button>

            <div className="w-px h-4 bg-slate-700"/>

            {/* Settings gear */}
            <button
              onClick={() => setShowChartSettings(s => !s)}
              title="Configurações do gráfico"
              className={`w-7 h-7 flex items-center justify-center rounded transition ${showChartSettings ? 'text-[#00E676] bg-slate-800' : 'text-slate-400 hover:text-white hover:bg-slate-800'}`}
            >
              <svg viewBox="0 0 24 24" width="15" height="15" fill="currentColor">
                <path d="M19.14 12.94c.04-.3.06-.61.06-.94s-.02-.64-.07-.94l2.03-1.58a.49.49 0 0 0 .12-.61l-1.92-3.32a.49.49 0 0 0-.59-.22l-2.39.96a6.97 6.97 0 0 0-1.62-.94l-.36-2.54a.484.484 0 0 0-.48-.41h-3.84c-.24 0-.43.17-.47.41l-.36 2.54c-.59.24-1.13.57-1.62.94l-2.39-.96c-.22-.08-.47 0-.59.22L2.74 8.87a.48.48 0 0 0 .12.61l2.03 1.58c-.05.3-.09.63-.09.94s.02.64.07.94l-2.03 1.58a.49.49 0 0 0-.12.61l1.92 3.32c.12.22.37.29.59.22l2.39-.96c.5.38 1.03.7 1.62.94l.36 2.54c.05.24.24.41.48.41h3.84c.24 0 .44-.17.47-.41l.36-2.54c.59-.24 1.13-.56 1.62-.94l2.39.96c.22.08.47 0 .59-.22l1.92-3.32a.49.49 0 0 0-.12-.61l-2.01-1.58zM12 15.6c-1.98 0-3.6-1.62-3.6-3.6s1.62-3.6 3.6-3.6 3.6 1.62 3.6 3.6-1.62 3.6-3.6 3.6z"/>
              </svg>
            </button>
          </div>

          {/* Floating Settings Panel */}
          {showChartSettings && (
            <div className="absolute top-12 left-2 z-30 bg-[#0F1520] border border-slate-700 rounded-xl shadow-2xl w-64 p-4 space-y-4">
              <div className="flex justify-between items-center">
                <span className="text-xs font-bold text-slate-300 uppercase tracking-wider">Configurações</span>
                <button onClick={() => setShowChartSettings(false)} className="text-slate-500 hover:text-white text-xs">✕</button>
              </div>

              {/* View Mode */}
              <div>
                <span className="text-[10px] text-slate-500 font-bold block mb-1">MODO DE EXIBIÇÃO</span>
                <div className="flex bg-[#151B26] border border-slate-700 rounded-md overflow-hidden">
                  <button onClick={() => setViewMode('bidask')} className={`flex-1 py-1 text-xs font-semibold ${viewMode === 'bidask' ? 'bg-[#00E676] text-slate-900' : 'text-slate-400 hover:bg-slate-800'}`}>Bid x Ask</button>
                  <button onClick={() => setViewMode('delta')} className={`flex-1 py-1 text-xs font-semibold ${viewMode === 'delta' ? 'bg-[#00E676] text-slate-900' : 'text-slate-400 hover:bg-slate-800'}`}>Delta</button>
                </div>
              </div>

              {/* Price Step */}
              <div>
                <span className="text-[10px] text-slate-500 font-bold block mb-1">PASSO DO PREÇO (ticks)</span>
                <div className="flex items-center bg-[#151B26] border border-slate-700 rounded-md overflow-hidden">
                  <button onClick={() => setStepMultiplier(s => Math.max(1, s - 25))} className="px-3 py-1.5 text-slate-400 hover:text-white hover:bg-slate-800">−</button>
                  <input
                    type="number"
                    min="1"
                    value={stepMultiplier}
                    onChange={e => setStepMultiplier(Math.max(1, Number(e.target.value) || 1))}
                    className="flex-1 bg-transparent text-center text-sm font-bold text-white outline-none [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
                  />
                  <button onClick={() => setStepMultiplier(s => s + 25)} className="px-3 py-1.5 text-slate-400 hover:text-white hover:bg-slate-800">+</button>
                </div>
              </div>

              {/* Close Mode */}
              <div>
                <span className="text-[10px] text-slate-500 font-bold block mb-1">MODO DE FECHAMENTO</span>
                <select
                  value={closeMode}
                  onChange={e => { setCloseMode(e.target.value); setConfigDirty(true); }}
                  className="w-full bg-[#151B26] border border-slate-700 rounded-md px-2 py-1.5 text-xs text-slate-300 outline-none"
                >
                  <option value="delta">Delta</option>
                  <option value="volume">Volume</option>
                  <option value="range">Range</option>
                  <option value="time">Tempo</option>
                </select>
              </div>

              {/* Delta Max */}
              {closeMode === 'delta' && (
                <div>
                  <span className="text-[10px] text-slate-500 font-bold block mb-1">DELTA MÁX</span>
                  <div className="flex items-center bg-[#151B26] border border-slate-700 rounded-md overflow-hidden">
                    <button onClick={() => { setDeltaMax(d => Math.max(100, d - 100)); setConfigDirty(true); }} className="px-3 py-1.5 text-slate-400 hover:text-white hover:bg-slate-800">−</button>
                    <input
                      type="number"
                      min="100"
                      step="100"
                      value={deltaMax}
                      onChange={e => { setDeltaMax(Math.max(100, Number(e.target.value) || 100)); setConfigDirty(true); }}
                      className="flex-1 bg-transparent text-center text-sm font-bold text-white outline-none [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
                    />
                    <button onClick={() => { setDeltaMax(d => d + 100); setConfigDirty(true); }} className="px-3 py-1.5 text-slate-400 hover:text-white hover:bg-slate-800">+</button>
                  </div>
                </div>
              )}

              {/* Apply */}
              <button
                onClick={() => { applyConfig(closeMode, deltaMax, volumeMax, timeSeconds, rangePoints); setShowChartSettings(false); }}
                disabled={!configDirty}
                className={`w-full py-1.5 rounded-md text-xs font-semibold transition ${configDirty ? 'bg-[#00E676] text-slate-900 hover:bg-[#00c853]' : 'bg-slate-800 text-slate-600 cursor-not-allowed'}`}
              >
                Aplicar
              </button>
            </div>
          )}

          <FootprintCanvas
            clusters={allClusters}
            tickSize={dynamicTickSize}
            stepMultiplier={stepMultiplier}
            viewMode={viewMode}
            imbalanceRatio={imbalanceRatio}
            onStepChange={setStepMultiplier}
            bid={lastBid}
            ask={lastAsk}
            domData={domData}
            bigTrades={bigTrades}
            centerTrigger={centerTrigger}
          />
        </div>

        {/* Info Sidebar Panel */}
        <aside className="w-80 flex flex-col gap-6 hidden lg:flex">
          {/* Active Statistics Card */}
          <section className="bg-[#151B26] border border-slate-800 rounded-xl p-5 shadow-lg">
            <h2 className="text-sm font-semibold text-slate-300 mb-4 border-b border-slate-800 pb-2">
              System Overview
            </h2>
            
            <div className="space-y-4">
              <div className="flex justify-between items-center text-xs">
                <span className="text-slate-400">Target Symbol:</span>
                <span className="font-mono font-semibold text-[#00B0FF] bg-[#00B0FF]/10 px-2 py-0.5 rounded">
                  {targetSymbol}
                </span>
              </div>
              <div className="flex flex-col sm:flex-row items-center gap-6">
                <div className="flex gap-8">
                  <div className="flex flex-col">
                    <span className="text-xs text-slate-500 font-medium">TOTAL VOLUME</span>
                    <span className="text-lg font-bold text-slate-200">{(totalVolume / 1000).toFixed(1)}k</span>
                  </div>
                  <div className="flex flex-col">
                    <span className="text-xs text-slate-500 font-medium">AVG VOL / CLUSTER</span>
                    <span className="text-lg font-bold text-slate-200">{avgVolumePerCluster}</span>
                  </div>
                </div>
                
                <div className="h-8 w-px bg-slate-800 hidden sm:block"></div>
                
                <div className="flex items-center gap-4">
                  <div className="flex flex-col">
                    <span className="text-[10px] text-slate-500 font-bold mb-1">PRICE STEP</span>
                    <div className="flex items-center bg-[#151B26] border border-slate-700 rounded-md overflow-hidden">
                      <button onClick={() => setStepMultiplier(s => Math.max(1, s - 25))} className="px-2 py-1 text-slate-400 hover:text-white hover:bg-slate-800">-</button>
                      <input
                        type="number"
                        min="1"
                        value={stepMultiplier}
                        onChange={e => setStepMultiplier(Math.max(1, Number(e.target.value) || 1))}
                        className="px-1 py-1 text-sm font-bold text-white min-w-[52px] text-center bg-transparent outline-none [appearance:textfield] [&::-webkit-outer-spin-button]:appearance-none [&::-webkit-inner-spin-button]:appearance-none"
                      />
                      <button onClick={() => setStepMultiplier(s => s + 25)} className="px-2 py-1 text-slate-400 hover:text-white hover:bg-slate-800">+</button>
                    </div>
                  </div>
                  
                  <div className="flex flex-col">
                    <span className="text-[10px] text-slate-500 font-bold mb-1">VIEW MODE</span>
                    <div className="flex bg-[#151B26] border border-slate-700 rounded-md overflow-hidden">
                      <button 
                        onClick={() => setViewMode('bidask')} 
                        className={`px-3 py-1 text-xs font-semibold ${viewMode === 'bidask' ? 'bg-[#00E676] text-slate-900' : 'text-slate-400 hover:bg-slate-800'}`}
                      >
                        Bid x Ask
                      </button>
                      <button 
                        onClick={() => setViewMode('delta')} 
                        className={`px-3 py-1 text-xs font-semibold ${viewMode === 'delta' ? 'bg-[#00E676] text-slate-900' : 'text-slate-400 hover:bg-slate-800'}`}
                      >
                        Delta
                      </button>
                    </div>
                  </div>
                </div>

                <div className="flex items-center gap-4 mt-4">
                  <div className="flex flex-col flex-1">
                    <div className="flex justify-between mb-1">
                      <span className="text-[10px] text-slate-500 font-bold">IMBALANCE RATIO</span>
                      <span className="text-[10px] font-mono text-slate-300">{imbalanceRatio}%</span>
                    </div>
                    <input 
                      type="range" 
                      min="150" 
                      max="500" 
                      step="10" 
                      value={imbalanceRatio} 
                      onChange={(e) => setImbalanceRatio(parseInt(e.target.value))}
                      className="w-full accent-[#00B0FF] bg-slate-800 rounded-lg h-1.5 appearance-none cursor-pointer"
                    />
                  </div>
                </div>
              </div>
              <div className="flex justify-between items-center text-xs mt-4 border-t border-slate-800 pt-4">
                <span className="text-slate-400">Closed Clusters:</span>
                <span className="font-mono text-slate-200">{history.length}</span>
              </div>
            </div>
          </section>

          {/* Cluster Formation Config */}
          <section className="bg-[#151B26] border border-slate-800 rounded-xl p-5 shadow-lg">
            <h2 className="text-sm font-semibold text-slate-300 mb-4 border-b border-slate-800 pb-2">
              Cluster Formation
            </h2>
            <div className="space-y-4 text-xs">
              {/* Close mode */}
              <div>
                <span className="text-[10px] text-slate-500 font-bold block mb-1">CLOSE MODE</span>
                <div className="flex bg-[#0B0E14] border border-slate-700 rounded-md overflow-hidden">
                  {['delta', 'range', 'time', 'volume'].map(m => (
                    <button
                      key={m}
                      onClick={() => { setCloseMode(m); setConfigDirty(true); }}
                      className={`flex-1 py-1 text-[10px] font-semibold uppercase ${closeMode === m ? 'bg-[#00E676] text-slate-900' : 'text-slate-400 hover:bg-slate-800'}`}
                    >{m}</button>
                  ))}
                </div>
              </div>

              {/* Range thresholds */}
              {closeMode === 'delta' && (
                <div>
                  <div className="flex justify-between mb-1">
                    <span className="text-[10px] text-slate-500 font-bold">DELTA THRESHOLD</span>
                    <span className="text-[10px] font-mono text-slate-300">{deltaMax.toLocaleString()}</span>
                  </div>
                  <input
                    type="range" min="100" max="10000" step="50"
                    value={deltaMax}
                    onChange={e => { setDeltaMax(Number(e.target.value)); setConfigDirty(true); }}
                    className="w-full accent-[#00E676] bg-slate-800 rounded-lg h-1.5 appearance-none cursor-pointer"
                  />
                </div>
              )}
              {closeMode === 'volume' && (
                <div>
                  <div className="flex justify-between mb-1">
                    <span className="text-[10px] text-slate-500 font-bold">VOLUME THRESHOLD</span>
                    <span className="text-[10px] font-mono text-slate-300">{volumeMax.toLocaleString()}</span>
                  </div>
                  <input
                    type="range" min="100" max="20000" step="100"
                    value={volumeMax}
                    onChange={e => { setVolumeMax(Number(e.target.value)); setConfigDirty(true); }}
                    className="w-full accent-[#00E676] bg-slate-800 rounded-lg h-1.5 appearance-none cursor-pointer"
                  />
                </div>
              )}
              {closeMode === 'time' && (
                <div>
                  <div className="flex justify-between mb-1">
                    <span className="text-[10px] text-slate-500 font-bold">TIME THRESHOLD (seconds)</span>
                    <span className="text-[10px] font-mono text-slate-300">{timeSeconds}s</span>
                  </div>
                  <input
                    type="range" min="30" max="3600" step="30"
                    value={timeSeconds}
                    onChange={e => { setTimeSeconds(Number(e.target.value)); setConfigDirty(true); }}
                    className="w-full accent-[#00E676] bg-slate-800 rounded-lg h-1.5 appearance-none cursor-pointer"
                  />
                </div>
              )}
              {closeMode === 'range' && (
                <div>
                  <div className="flex justify-between mb-1">
                    <span className="text-[10px] text-slate-500 font-bold">RANGE THRESHOLD (points)</span>
                    <span className="text-[10px] font-mono text-slate-300">{rangePoints}</span>
                  </div>
                  <input
                    type="range" min="1" max="500" step="1"
                    value={rangePoints}
                    onChange={e => { setRangePoints(Number(e.target.value)); setConfigDirty(true); }}
                    className="w-full accent-[#00E676] bg-slate-800 rounded-lg h-1.5 appearance-none cursor-pointer"
                  />
                </div>
              )}

              {/* Apply button */}
              <button
                onClick={() => applyConfig(closeMode, deltaMax, volumeMax, timeSeconds, rangePoints)}
                disabled={!configDirty}
                className={`w-full py-1.5 rounded-md text-xs font-semibold transition ${configDirty ? 'bg-[#00E676] text-slate-900 hover:bg-[#00c853]' : 'bg-slate-800 text-slate-600 cursor-not-allowed'}`}
              >
                {configDirty ? 'Apply' : 'Applied'}
              </button>
            </div>
          </section>

          {/* Aggregator Settings Rules Indicator */}
          <section className="bg-[#151B26] border border-slate-800 rounded-xl p-5 shadow-lg flex-1">
            <h2 className="text-sm font-semibold text-slate-300 mb-4 border-b border-slate-800 pb-2">
              Aggregator Rules
            </h2>
            
            <div className="text-xs space-y-3.5 text-slate-400">
              <div>
                <p className="text-slate-300 font-medium mb-1">Diagonal Imbalance</p>
                <code className="block bg-[#0B0E14] p-2 rounded text-[10px] text-slate-400 leading-relaxed font-mono">
                  BUY: ask[i] &ge; 3.0 &times; bid[i-1]<br />
                  SELL: bid[i] &ge; 3.0 &times; ask[i+1]
                </code>
              </div>

              <div>
                <p className="text-slate-300 font-medium mb-1">Stacked Imbalance Zone</p>
                <p className="leading-relaxed">
                  Triggered on <span className="text-white font-semibold">3+</span> consecutive diagonal imbalances in the same direction. Highlighting horizontal zones.
                </p>
              </div>

              <div>
                <p className="text-slate-300 font-medium mb-1">POC (Point of Control)</p>
                <p className="leading-relaxed">
                  Level containing the highest total volume within the cluster. Highlighted with a <span className="text-[#FFD600] font-semibold">Gold border</span>.
                </p>
              </div>
            </div>
          </section>

          {/* Quick Guide Footer */}
          <footer className="text-[11px] text-slate-500 text-center leading-relaxed">
            Drag to pan horizontally & vertically.<br />
            Use scroll wheel to move vertical scale.<br />
            Hold Shift + scroll wheel to scroll horizontal.
          </footer>
          {/* Trading Panel (Phase 5) */}
          <section className="bg-[#151B26] border border-slate-800 rounded-xl p-5 shadow-lg">
            <h2 className="text-sm font-semibold text-slate-300 mb-4 border-b border-slate-800 pb-2">
              Trading Execution
            </h2>
            <div className="space-y-3">
              <div className="flex gap-2">
                <button
                  onClick={async () => {
                    const res = await fetch(`${API_URL}/trade/buy`, { method: 'POST' });
                    if (res.ok) pushToast("Buy Signal Sent (MQL5)", "info");
                  }}
                  className="flex-1 bg-blue-600 hover:bg-blue-500 text-white font-bold py-2 rounded shadow-md transition-colors text-sm"
                >
                  BUY MKT
                </button>
                <button
                  onClick={async () => {
                    const res = await fetch(`${API_URL}/trade/sell`, { method: 'POST' });
                    if (res.ok) pushToast("Sell Signal Sent (MQL5)", "warning");
                  }}
                  className="flex-1 bg-red-600 hover:bg-red-500 text-white font-bold py-2 rounded shadow-md transition-colors text-sm"
                >
                  SELL MKT
                </button>
              </div>
              <div className="text-[10px] text-slate-500 text-center leading-tight">
                Executes via MQL5 CTrade API with OCO brackets.<br/>Latência estimada: &lt; 20ms
              </div>
            </div>
          </section>

        </aside>
      </main>
    </div>
  );
}
