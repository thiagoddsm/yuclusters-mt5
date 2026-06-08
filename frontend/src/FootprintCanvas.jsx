import React, { useRef, useEffect, useState } from 'react';

export default function FootprintCanvas({ clusters, tickSize = 1.0, stepMultiplier = 1, viewMode = 'bidask', imbalanceRatio = 300, onStepChange, bid = 0, ask = 0, domData = null, bigTrades = [] }) {
  const canvasRef = useRef(null);

  // Navigation & Scale State
  const [scrollOffset, setScrollOffset] = useState({ x: 50, y: 0 }); // X: horizontal offset, Y: vertical offset
  const [zoom, setZoom] = useState(1); // Zoom level
  const [isDragging, setIsDragging] = useState(false);
  const [cursor, setCursor] = useState('grab');
  const dragStart = useRef({ x: 0, y: 0 });
  const dragOffsetStart = useRef({ x: 0, y: 0 });

  // Price axis drag (scale) state
  const isDraggingAxis = useRef(false);
  const axisDragStartY = useRef(0);
  const axisDragStartStep = useRef(0);

  // Time axis drag (horizontal zoom) state
  const isDraggingTimeAxis = useRef(false);
  const timeAxisDragStartX = useRef(0);
  const timeAxisDragStartZoom = useRef(1);
  
  // Apply zoom to sizes
  const colWidth = 140 * zoom; // width of each cluster column
  const colGap = 15 * zoom;    // gap between columns
  const rowHeight = 26 * zoom; // height of each price cell
  const axisWidth = 70; // width of the vertical price axis on the right

  // Auto-scroll to keep latest cluster visible whenever clusters or zoom changes
  const lastClusterCount = useRef(0);
  useEffect(() => {
    if (clusters && canvasRef.current) {
      const canvas = canvasRef.current;
      const rect = canvas.getBoundingClientRect();
      const visibleWidth = rect.width - axisWidth - 160; // leave space for vol profile
      const totalClustersWidth = clusters.length * (colWidth + colGap);
      // Pin latest cluster to right side of visible area
      const newX = visibleWidth - totalClustersWidth;
      setScrollOffset(prev => ({ ...prev, x: newX }));
      lastClusterCount.current = clusters.length;
    }
  }, [clusters?.length, zoom]);

  // Main Render Loop
  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    
    // Handle High DPI displays
    const dpr = window.devicePixelRatio || 1;
    const rect = canvas.getBoundingClientRect();
    canvas.width = rect.width * dpr;
    canvas.height = rect.height * dpr;
    ctx.scale(dpr, dpr);
    
    const width = rect.width;
    const height = rect.height;
    
    // Split View Layout
    const bottomPanelHeight = 100;
    const chartHeight = height - bottomPanelHeight;
    
    // Clear screen
    ctx.fillStyle = '#0B0E14';
    ctx.fillRect(0, 0, width, height);
    
    // Draw Grid Background
    ctx.strokeStyle = '#151B26';
    ctx.lineWidth = 1;
    for (let x = 0; x < width; x += 50) {
      ctx.beginPath();
      ctx.moveTo(x, 0);
      ctx.lineTo(x, height);
      ctx.stroke();
    }
    for (let y = 0; y < height; y += 50) {
      ctx.beginPath();
      ctx.moveTo(0, y);
      ctx.lineTo(width, y);
      ctx.stroke();
    }

    if (!clusters || clusters.length === 0) {
      ctx.fillStyle = '#64748B';
      ctx.font = '16px Outfit, sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText('Waiting for market data from MetaTrader 5...', width / 2, height / 2);
      return;
    }

    // Determine the baseline price to align Y coordinates
    const latestCluster = clusters[clusters.length - 1];
    const basePrice = latestCluster.poc || 0;
    const actualTickSize = (latestCluster.tick_size || tickSize) * stepMultiplier;
    const centerY = chartHeight / 2 + scrollOffset.y;

    // Helper to get Y coordinate for a given price
    const getPriceY = (price) => {
      const diffTicks = (price - basePrice) / actualTickSize;
      return centerY - (diffTicks * rowHeight);
    };

    // Helper to get price from Y coordinate (for axis rendering)
    const getYPrice = (y) => {
      const diffTicks = (centerY - y) / rowHeight;
      return basePrice + (diffTicks * actualTickSize);
    };

    // Bottom panel layout
    const bottomPanelH = bottomPanelHeight;
    const panelBaseY = height - bottomPanelH;
    const barMaxH = 52;          // max height a single bar can reach
    const barBaseY = panelBaseY + 58;  // y where bars touch the floor

    // Pre-compute max bid or ask side across all clusters (for proportional scaling)
    const maxSideVolume = Math.max(...clusters.map(c => {
      const lvls = Object.values(c.levels || {});
      const b = lvls.reduce((s, l) => s + (l.bid || 0), 0);
      const a = lvls.reduce((s, l) => s + (l.ask || 0), 0);
      return Math.max(b, a);
    }), 1);

    // Draw bottom panel background BEFORE cluster loop so bars render on top
    ctx.fillStyle = '#0B0E14';
    ctx.fillRect(0, panelBaseY, width, bottomPanelH);
    ctx.strokeStyle = '#1E293B';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(0, panelBaseY);
    ctx.lineTo(width, panelBaseY);
    ctx.stroke();

    // Draw Columns (Clusters)
    clusters.forEach((cluster, index) => {
      // Calculate column X position
      // Offset starting after the Volume Profile panel (width 140)
      const colX = scrollOffset.x + index * (colWidth + colGap);
      
      // Don't render if outside canvas bounds (horizontal clipping)
      if (colX + colWidth < 0 || colX > width - axisWidth) return;

      let levels = cluster.levels || {};
      
      // Dynamic Binning based on stepMultiplier
      if (stepMultiplier > 1) {
         const binnedLevels = {};
         Object.keys(levels).forEach(pStr => {
            const p = parseFloat(pStr);
            const data = levels[pStr];
            const binPrice = Math.round(p / actualTickSize) * actualTickSize;
            
            if (!binnedLevels[binPrice]) {
               binnedLevels[binPrice] = { ask: 0, bid: 0, total: 0, delta: 0, imbalance: null };
            }
            binnedLevels[binPrice].ask += data.ask || 0;
            binnedLevels[binPrice].bid += data.bid || 0;
            binnedLevels[binPrice].total += data.total || 0;
            binnedLevels[binPrice].delta += data.delta || 0;
            
            const ratio = imbalanceRatio / 100.0;
            if (binnedLevels[binPrice].ask >= binnedLevels[binPrice].bid * ratio && binnedLevels[binPrice].ask > 0) {
               binnedLevels[binPrice].imbalance = 'buy';
            } else if (binnedLevels[binPrice].bid >= binnedLevels[binPrice].ask * ratio && binnedLevels[binPrice].bid > 0) {
               binnedLevels[binPrice].imbalance = 'sell';
            }
         });
         levels = binnedLevels;
      }
      // Sort string keys numerically, but keep them as strings to avoid trailing zero lookup issues
      const pricesStr = Object.keys(levels).sort((a, b) => Number(b) - Number(a));

      if (pricesStr.length === 0) return;

      const numericPrices = pricesStr.map(Number);
      const highestPrice = Math.max(...numericPrices);
      const lowestPrice = Math.min(...numericPrices);

      // Draw Stacked Imbalance background zone if present
      if (cluster.stacked && (cluster.stacked.buy || cluster.stacked.sell)) {
        const stackedPrices = cluster.stacked.price_range || [];
        if (stackedPrices.length > 0) {
          const sHigh = Math.max(...stackedPrices);
          const sLow = Math.min(...stackedPrices);
          const yTop = getPriceY(sHigh) - rowHeight / 2;
          const yBottom = getPriceY(sLow) + rowHeight / 2;
          
          const grad = ctx.createLinearGradient(colX - 8, yTop, colX, yTop);
          if (cluster.stacked.buy) {
            grad.addColorStop(0, 'rgba(0, 230, 118, 0.4)');
            grad.addColorStop(1, 'rgba(0, 230, 118, 0.05)');
            ctx.fillStyle = grad;
          } else {
            grad.addColorStop(0, 'rgba(255, 23, 68, 0.4)');
            grad.addColorStop(1, 'rgba(255, 23, 68, 0.05)');
            ctx.fillStyle = grad;
          }
          ctx.fillRect(colX - 10, yTop, 10, yBottom - yTop);
          
          // Draw thin outline
          ctx.strokeStyle = cluster.stacked.buy ? '#00E676' : '#FF1744';
          ctx.lineWidth = 1;
          ctx.beginPath();
          ctx.moveTo(colX - 10, yTop);
          ctx.lineTo(colX - 10, yBottom);
          ctx.stroke();
        }
      }


      // OHLC body range — levels outside = wicks (just a line)
      const bodyHigh = (cluster.open_price !== undefined && cluster.close_price !== undefined)
        ? Math.max(cluster.open_price, cluster.close_price)
        : highestPrice;
      const bodyLow = (cluster.open_price !== undefined && cluster.close_price !== undefined)
        ? Math.min(cluster.open_price, cluster.close_price)
        : lowestPrice;
      const isBull = cluster.close_price >= cluster.open_price;

      // OHLC body border rectangle
      if (cluster.open_price !== undefined && cluster.close_price !== undefined) {
        const openY  = getPriceY(cluster.open_price);
        const closeY = getPriceY(cluster.close_price);
        const candleTop    = Math.min(openY, closeY) - rowHeight / 2;
        const candleBottom = Math.max(openY, closeY) + rowHeight / 2;
        ctx.strokeStyle = isBull ? 'rgba(0, 230, 118, 0.55)' : 'rgba(255, 23, 68, 0.55)';
        ctx.lineWidth = 1.5;
        ctx.strokeRect(colX - 2, candleTop, colWidth + 4, Math.max(2, candleBottom - candleTop));

        // Wick lines (thin center line above body to high, below body to low)
        const highY = getPriceY(highestPrice);
        const lowY  = getPriceY(lowestPrice);
        ctx.strokeStyle = isBull ? 'rgba(0, 230, 118, 0.4)' : 'rgba(255, 23, 68, 0.4)';
        ctx.lineWidth = 1;
        if (highestPrice > bodyHigh) {
          ctx.beginPath();
          ctx.moveTo(colX + colWidth / 2, highY);
          ctx.lineTo(colX + colWidth / 2, candleTop);
          ctx.stroke();
        }
        if (lowestPrice < bodyLow) {
          ctx.beginPath();
          ctx.moveTo(colX + colWidth / 2, candleBottom);
          ctx.lineTo(colX + colWidth / 2, lowY + rowHeight);
          ctx.stroke();
        }
      }

      const fmtK = (v) => {
        const n = Math.abs(v);
        if (n >= 1000) return (v / 1000).toFixed(1) + 'K';
        return v.toFixed(0);
      };

      // Max volume in cluster for proportional bars
      const maxVol = Math.max(...Object.values(levels).map(l => Math.max(l.ask || 0, l.bid || 0)), 1);

      const fontSize = Math.max(6, 11 * zoom);
      ctx.font = `bold ${fontSize}px JetBrains Mono, monospace`;
      ctx.textBaseline = 'middle';

      // Draw Cells — one color per level (dominant side), number only at POC
      pricesStr.forEach((priceStr, i) => {
        const price = Number(priceStr);
        const cellData = levels[priceStr];

        const cellY = getPriceY(price) - rowHeight / 2;
        if (cellY + rowHeight < 0 || cellY > height) return;

        const isWick = price < bodyLow - actualTickSize * 0.5 || price > bodyHigh + actualTickSize * 0.5;
        const alpha = isWick ? 0.4 : 0.85;

        const bid = cellData.bid || 0;
        const ask = cellData.ask || 0;
        const dominant    = ask >= bid ? 'ask' : 'bid';
        const dominantVal = Math.max(ask, bid);

        // Single proportional bar — dominant color only, grows left to right
        const barW = Math.min((dominantVal / maxVol) * colWidth, colWidth);
        ctx.fillStyle = dominant === 'ask'
          ? `rgba(59, 130, 246, ${alpha})`
          : `rgba(236, 72, 153, ${alpha})`;
        ctx.fillRect(colX, cellY + 1, barW, rowHeight - 3);


        // POC border (rectangle only at POC level)
        if (!isWick && price === cluster.poc) {
          ctx.strokeStyle = '#FFD600';
          ctx.lineWidth = 2;
          ctx.strokeRect(colX + 1, cellY + 1, colWidth - 2, rowHeight - 4);
        }

        // Number only at POC (inside bar, right-aligned)
        if (zoom >= 0.5 && !isWick && price === cluster.poc) {
          const cy = cellY + rowHeight / 2;
          if (viewMode === 'delta') {
            const d = cellData.delta || 0;
            ctx.fillStyle = d >= 0 ? '#00E676' : '#FF1744';
            ctx.textAlign = 'right';
            ctx.fillText((d >= 0 ? '+' : '') + fmtK(d), colX + colWidth - 4, cy);
          } else {
            ctx.fillStyle = 'rgba(255,255,255,0.95)';
            ctx.textAlign = 'right';
            ctx.fillText(fmtK(dominantVal), colX + colWidth - 4, cy);
          }
        }
      });

      // Render Extremes Ratios (Informers)
      const adv = cluster.advanced_metrics;
      if (adv) {
         ctx.font = '10px JetBrains Mono, monospace';
         ctx.textAlign = 'center';
         ctx.textBaseline = 'middle';
         
         const highY = getPriceY(highestPrice) - rowHeight;
         const lowY = getPriceY(lowestPrice) + rowHeight;
         
         // Top Ratio
         if (adv.high_ratio !== undefined) {
             const hRatio = adv.high_ratio;
             ctx.fillStyle = hRatio < 0.7 ? '#FFD600' : '#64748B'; // Gold if exhaustion
             ctx.fillText(hRatio.toFixed(2), colX + colWidth / 2, highY);
         }
         
         // Bottom Ratio
         if (adv.low_ratio !== undefined) {
             const lRatio = adv.low_ratio;
             ctx.fillStyle = lRatio < 0.7 ? '#FFD600' : '#64748B'; // Gold if exhaustion
             ctx.fillText(lRatio.toFixed(2), colX + colWidth / 2, lowY);
         }
      }

      // Draw Top/Bottom Extreme Markers
      if (adv) {
        if (adv.top_extreme === 'exhaustion' || adv.top_extreme === 'absorption') {
           const topY = getPriceY(highestPrice) - rowHeight / 2;
           ctx.strokeStyle = adv.top_extreme === 'absorption' ? '#FF9800' : '#2196F3'; // Orange for Absorption, Blue for Exhaustion
           ctx.lineWidth = adv.top_extreme === 'absorption' ? 3 : 1.5;
           ctx.beginPath();
           ctx.moveTo(colX, topY);
           ctx.lineTo(colX + colWidth, topY);
           ctx.stroke();
        }
         if (adv.bottom_extreme === 'exhaustion' || adv.bottom_extreme === 'absorption') {
           const bottomY = getPriceY(lowestPrice) + rowHeight / 2;
           ctx.strokeStyle = adv.bottom_extreme === 'absorption' ? '#FF9800' : '#2196F3';
           ctx.lineWidth = adv.bottom_extreme === 'absorption' ? 3 : 1.5;
           ctx.beginPath();
           ctx.moveTo(colX, bottomY);
           ctx.lineTo(colX + colWidth, bottomY);
           ctx.stroke();
         }
      }

      // Bottom Panel — two side-by-side bars: bid (sell/red) left, ask (buy/blue) right
      const bidTotal = pricesStr.reduce((s, p) => s + (levels[p]?.bid || 0), 0);
      const askTotal = pricesStr.reduce((s, p) => s + (levels[p]?.ask || 0), 0);

      const halfW = Math.floor((colWidth - 4) / 2);
      const gap = 2;

      // Bid bar (left, sell = red)
      const bidBarH = Math.max(2, (bidTotal / maxSideVolume) * barMaxH);
      ctx.fillStyle = 'rgba(210, 38, 38, 0.9)';
      ctx.fillRect(colX + 1, barBaseY - bidBarH, halfW, bidBarH);

      // Ask bar (right, buy = blue)
      const askBarH = Math.max(2, (askTotal / maxSideVolume) * barMaxH);
      ctx.fillStyle = 'rgba(37, 99, 235, 0.9)';
      ctx.fillRect(colX + halfW + gap + 1, barBaseY - askBarH, halfW, askBarH);

      // Volume label — white, inside the bars at the bottom
      const totalVol = cluster.total_volume || 0;
      const volLabel = totalVol >= 1000 ? (totalVol / 1000).toFixed(1) + 'K' : totalVol.toFixed(0);
      const delta = cluster.total_delta || 0;
      ctx.fillStyle = '#FFFFFF';
      ctx.font = 'bold 11px JetBrains Mono, monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'bottom';
      ctx.fillText(volLabel, colX + colWidth / 2, barBaseY - 2);

      // Delta block with value — sits below the bars
      const deltaBlockY = barBaseY + 2;
      const deltaBlockH = 18;
      ctx.fillStyle = delta >= 0 ? '#1D4ED8' : '#991B1B';
      ctx.fillRect(colX + 1, deltaBlockY, colWidth - 2, deltaBlockH);
      ctx.fillStyle = '#FFFFFF';
      ctx.font = 'bold 10px JetBrains Mono, monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText(delta.toFixed(0), colX + colWidth / 2, deltaBlockY + deltaBlockH / 2);

      // Timestamp at the very bottom
      if (cluster.open_time) {
        const timeStr = new Date(cluster.open_time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
        ctx.fillStyle = '#94A3B8';
        ctx.font = '9px JetBrains Mono, monospace';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'bottom';
        ctx.fillText(timeStr, colX + colWidth / 2, height - 2);
      }
      
    });

    // Draw Volume Profile Overlay Panel (Left Side)
    const volProfileWidth = 140;
    const volumeProfile = {};
    const deltaProfile = {}; // Phase 5
    let maxProfileVolume = 0;
    let maxDeltaAbs = 0;
    
    // VWAP Calculation
    let cumulativeVolume = 0;
    let cumulativePriceVolume = 0;

    clusters.forEach(cluster => {
      const lvls = cluster.levels || {};
      Object.keys(lvls).forEach(pStr => {
        const p = parseFloat(pStr);
        const data = lvls[pStr];
        const binPrice = Math.round(p / actualTickSize) * actualTickSize;
        
        const vol = data.total || 0;
        const delta = (data.buy_vol || 0) - (data.sell_vol || 0);

        volumeProfile[binPrice] = (volumeProfile[binPrice] || 0) + vol;
        deltaProfile[binPrice] = (deltaProfile[binPrice] || 0) + delta;
        
        cumulativeVolume += vol;
        cumulativePriceVolume += (binPrice * vol);

        if (volumeProfile[binPrice] > maxProfileVolume) {
          maxProfileVolume = volumeProfile[binPrice];
        }
        if (Math.abs(deltaProfile[binPrice]) > maxDeltaAbs) {
          maxDeltaAbs = Math.abs(deltaProfile[binPrice]);
        }
      });
    });
    
    const vwap = cumulativeVolume > 0 ? (cumulativePriceVolume / cumulativeVolume) : null;
    
    // Value Area Calculation (70% of total volume)
    let totalDayVolume = 0;
    let dayPocPrice = null;
    let dayPocVol = -1;
    
    Object.keys(volumeProfile).forEach(pStr => {
      const vol = volumeProfile[pStr];
      totalDayVolume += vol;
      if (vol > dayPocVol) {
        dayPocVol = vol;
        dayPocPrice = parseFloat(pStr);
      }
    });

    let vah = dayPocPrice;
    let val = dayPocPrice;

    if (totalDayVolume > 0 && dayPocPrice !== null) {
      let currentValVol = dayPocVol;
      const targetVol = totalDayVolume * 0.70;
      let upperPrice = dayPocPrice + actualTickSize;
      let lowerPrice = dayPocPrice - actualTickSize;

      while (currentValVol < targetVol) {
        const upperVol = volumeProfile[upperPrice.toString()] || 0;
        const lowerVol = volumeProfile[lowerPrice.toString()] || 0;

        if (upperVol === 0 && lowerVol === 0) {
          break; // No more volume to add
        }

        if (upperVol >= lowerVol) {
          currentValVol += upperVol;
          vah = upperPrice;
          upperPrice += actualTickSize;
        } else {
          currentValVol += lowerVol;
          val = lowerPrice;
          lowerPrice -= actualTickSize;
        }
      }
    }

    // Draw VAH, VAL, and POC Lines across the chart
    if (dayPocPrice !== null) {
      const pocY = getPriceY(dayPocPrice);
      const vahY = getPriceY(vah);
      const valY = getPriceY(val);

      // VAH Line
      ctx.strokeStyle = 'rgba(148, 163, 184, 0.5)'; // Slate-400 dashed
      ctx.lineWidth = 1;
      ctx.setLineDash([4, 4]);
      ctx.beginPath(); ctx.moveTo(0, vahY); ctx.lineTo(width, vahY); ctx.stroke();
      
      // VAL Line
      ctx.beginPath(); ctx.moveTo(0, valY); ctx.lineTo(width, valY); ctx.stroke();
      ctx.setLineDash([]);

      // POC Line
      ctx.strokeStyle = 'rgba(255, 214, 0, 0.6)'; // Gold solid
      ctx.lineWidth = 1.5;
      ctx.beginPath(); ctx.moveTo(0, pocY); ctx.lineTo(width, pocY); ctx.stroke();
      
      // POC Label
      ctx.fillStyle = '#FFD600';
      ctx.font = '10px JetBrains Mono, monospace';
      ctx.textAlign = 'right';
      ctx.fillText('POC', width - axisWidth - 5, pocY - 5);
    }
    
    if (maxProfileVolume > 0) {
      // Solid background for the panel to cover grid/clusters underneath
      ctx.fillStyle = 'rgba(15, 20, 30, 0.85)';
      ctx.fillRect(0, 0, volProfileWidth, chartHeight);
      
      // Right border of panel
      ctx.strokeStyle = '#2A364F';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(volProfileWidth, 0);
      ctx.lineTo(volProfileWidth, chartHeight);
      ctx.stroke();

      // Histogram bars
      Object.keys(volumeProfile).forEach(pStr => {
        const price = parseFloat(pStr);
        const vol = volumeProfile[pStr];
        const y = getPriceY(price) - rowHeight / 2;
        const barWidth = (vol / maxProfileVolume) * (volProfileWidth - 5);
        
        // Highlight bars inside Value Area
        if (price <= vah && price >= val) {
           ctx.fillStyle = 'rgba(59, 130, 246, 0.6)'; // Stronger blue for Value Area
        } else {
           ctx.fillStyle = 'rgba(59, 130, 246, 0.2)'; // Faded blue outside Value Area
        }
        
        ctx.fillRect(0, y, barWidth, rowHeight - 2);
        
        // Draw Delta Profile inside the Volume bar
        const delta = deltaProfile[pStr] || 0;
        if (maxDeltaAbs > 0 && delta !== 0) {
          const deltaBarWidth = (Math.abs(delta) / maxDeltaAbs) * (volProfileWidth - 5) * 0.5; // Max 50% width
          ctx.fillStyle = delta > 0 ? 'rgba(0, 230, 118, 0.7)' : 'rgba(255, 23, 68, 0.7)';
          ctx.fillRect(0, y + rowHeight / 2 - 2, deltaBarWidth, 4);
        }
      });
      
      // Draw VWAP Line
      if (vwap !== null) {
        const vwapY = getPriceY(vwap);
        ctx.strokeStyle = '#FF4081'; // Pink VWAP
        ctx.lineWidth = 2;
        ctx.setLineDash([5, 5]);
        ctx.beginPath();
        ctx.moveTo(0, vwapY);
        ctx.lineTo(width, vwapY);
        ctx.stroke();
        ctx.setLineDash([]);
        
        // VWAP Label
        ctx.fillStyle = '#FF4081';
        ctx.font = 'bold 10px JetBrains Mono, monospace';
        ctx.textAlign = 'right';
        ctx.fillText('VWAP', width - axisWidth - 5, vwapY - 5);
      }
      
      // Panel Title
      ctx.fillStyle = '#94A3B8';
      ctx.font = '10px JetBrains Mono, monospace';
      ctx.textAlign = 'center';
      ctx.fillText('VOL & DELTA PROF', volProfileWidth / 2, 20);
    }

    // --- DOM (Depth of Market) Visualization (Phase 5) ---
    if (domData) {
      const maxDomVol = Math.max(
        ...((domData.asks || []).map(d => d[1])),
        ...((domData.bids || []).map(d => d[1])),
        1
      );
      const maxDomWidth = 100; // pixels
      const domBaseX = width - axisWidth;

      // Draw Asks
      (domData.asks || []).forEach(([p, v]) => {
        const y = getPriceY(p) - rowHeight / 2;
        const barW = (v / maxDomVol) * maxDomWidth;
        ctx.fillStyle = 'rgba(239, 68, 68, 0.4)'; // Red for asks
        ctx.fillRect(domBaseX - barW, y, barW, rowHeight - 2);
        ctx.fillStyle = 'rgba(239, 68, 68, 0.9)';
        ctx.font = '9px JetBrains Mono, monospace';
        ctx.textAlign = 'right';
        ctx.fillText(v.toString(), domBaseX - barW - 4, y + rowHeight / 2 + 3);
      });

      // Draw Bids
      (domData.bids || []).forEach(([p, v]) => {
        const y = getPriceY(p) - rowHeight / 2;
        const barW = (v / maxDomVol) * maxDomWidth;
        ctx.fillStyle = 'rgba(59, 130, 246, 0.4)'; // Blue for bids
        ctx.fillRect(domBaseX - barW, y, barW, rowHeight - 2);
        ctx.fillStyle = 'rgba(59, 130, 246, 0.9)';
        ctx.font = '9px JetBrains Mono, monospace';
        ctx.textAlign = 'right';
        ctx.fillText(v.toString(), domBaseX - barW - 4, y + rowHeight / 2 + 3);
      });
    }

    // --- Big Trades Visualization ---
    if (bigTrades && bigTrades.length > 0 && clusters.length > 0) {
      // Find the last cluster's X
      const lastColIdx = clusters.length - 1;
      const totalClustersWidth = clusters.length * (colWidth + colGap);
      const startX = width - axisWidth - scrollOffset.x - totalClustersWidth + 100;
      const lastColX = startX + lastColIdx * (colWidth + colGap);

      bigTrades.forEach(bt => {
        const y = getPriceY(bt.price);
        // Draw a glowing circle for the Big Trade
        ctx.beginPath();
        ctx.arc(lastColX + colWidth / 2, y, 12, 0, 2 * Math.PI);
        ctx.fillStyle = bt.is_buy ? 'rgba(59, 130, 246, 0.8)' : 'rgba(239, 68, 68, 0.8)';
        ctx.fill();
        ctx.lineWidth = 2;
        ctx.strokeStyle = '#FFF';
        ctx.stroke();
        
        // Volume text
        ctx.fillStyle = '#FFF';
        ctx.font = 'bold 9px Outfit';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(Math.round(bt.volume).toString(), lastColX + colWidth / 2, y);
      });
    }

    // Draw Vertical Price Axis (Right Side)
    ctx.fillStyle = 'rgba(11, 14, 20, 0.95)';
    ctx.fillRect(width - axisWidth, 0, axisWidth, chartHeight);
    
    ctx.strokeStyle = '#1E293B';
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(width - axisWidth, 0);
    ctx.lineTo(width - axisWidth, chartHeight);
    ctx.stroke();

    // Price axis labels — show every 10 rows to keep it clean
    const decimals = tickSize < 1 ? Math.max(0, -Math.floor(Math.log10(tickSize))) : 2;
    const labelStep = actualTickSize * 10; // one label every 10 price rows
    const topPrice    = getYPrice(0);
    const bottomPrice = getYPrice(chartHeight);
    const firstLabel  = Math.ceil(bottomPrice / labelStep) * labelStep;

    ctx.font = '10px JetBrains Mono, monospace';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';

    for (let p = firstLabel; p <= topPrice + labelStep; p += labelStep) {
      const labelY = getPriceY(p);
      if (labelY < 0 || labelY > chartHeight) continue;

      // Subtle horizontal grid line
      ctx.strokeStyle = 'rgba(30, 41, 59, 0.4)';
      ctx.lineWidth = 0.5;
      ctx.beginPath();
      ctx.moveTo(0, labelY);
      ctx.lineTo(width - axisWidth, labelY);
      ctx.stroke();

      // Small tick mark on axis border
      ctx.strokeStyle = '#334155';
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(width - axisWidth, labelY);
      ctx.lineTo(width - axisWidth + 4, labelY);
      ctx.stroke();

      ctx.fillStyle = '#64748B';
      ctx.fillText(p.toFixed(decimals), width - axisWidth + 8, labelY);
    }

    // Current Price Line — drawn last so it appears on top of everything
    const currentPrice = latestCluster.close_price;
    if (currentPrice) {
      const priceY = getPriceY(currentPrice);
      if (priceY >= 0 && priceY <= chartHeight) {
        ctx.strokeStyle = 'rgba(0, 229, 255, 0.9)';
        ctx.lineWidth = 1.5;
        ctx.setLineDash([6, 4]);
        ctx.beginPath();
        ctx.moveTo(volProfileWidth, priceY);
        ctx.lineTo(width - axisWidth, priceY);
        ctx.stroke();
        ctx.setLineDash([]);

        // Price tag on axis (on top of axis labels)
        const decimals = tickSize < 1 ? Math.max(0, -Math.floor(Math.log10(tickSize))) : 2;
        const priceLabel = currentPrice.toFixed(decimals);
        const tagH = 18;
        const tagW = axisWidth - 4;
        ctx.fillStyle = '#00E5FF';
        ctx.fillRect(width - axisWidth + 2, priceY - tagH / 2, tagW, tagH);
        ctx.fillStyle = '#000';
        ctx.font = 'bold 10px JetBrains Mono, monospace';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(priceLabel, width - axisWidth + 2 + tagW / 2, priceY);

        // Bid/Ask spread indicator below the price tag
        if (bid > 0 && ask > 0) {
          const askY = getPriceY(ask);
          const bidY = getPriceY(bid);
          const boxH = 16;
          const boxW = tagW;
          const boxX = width - axisWidth + 2;

          // Ask box (green)
          if (askY >= 0 && askY <= chartHeight) {
            ctx.fillStyle = '#1B5E20';
            ctx.fillRect(boxX, askY - boxH / 2, boxW, boxH);
            ctx.fillStyle = '#00E676';
            ctx.font = 'bold 9px JetBrains Mono, monospace';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillText(ask.toFixed(decimals), boxX + boxW / 2, askY);
          }

          // Spread arrow between ask and bid
          const midSpreadY = (askY + bidY) / 2;
          if (midSpreadY >= 0 && midSpreadY <= chartHeight) {
            ctx.fillStyle = '#94A3B8';
            ctx.font = '10px sans-serif';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillText('↕', boxX + boxW / 2, midSpreadY);
          }

          // Bid box (orange/red)
          if (bidY >= 0 && bidY <= chartHeight) {
            ctx.fillStyle = '#7C2D00';
            ctx.fillRect(boxX, bidY - boxH / 2, boxW, boxH);
            ctx.fillStyle = '#FB923C';
            ctx.font = 'bold 9px JetBrains Mono, monospace';
            ctx.textAlign = 'center';
            ctx.textBaseline = 'middle';
            ctx.fillText(bid.toFixed(decimals), boxX + boxW / 2, bidY);
          }
        }
      }
    }

  }, [clusters, scrollOffset]);

  // Mouse Interaction: Panning/Scrolling
  const handleMouseDown = (e) => {
    const rect = canvasRef.current.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    // Clicking on price axis → enter scale drag mode
    if (x > rect.width - axisWidth) {
      isDraggingAxis.current = true;
      axisDragStartY.current = y;
      axisDragStartStep.current = stepMultiplier;
      setCursor('ns-resize');
      return;
    }

    // Clicking on time axis (bottom panel) → horizontal zoom drag
    const chartH = rect.height - 100;
    if (y > chartH) {
      isDraggingTimeAxis.current = true;
      timeAxisDragStartX.current = x;
      timeAxisDragStartZoom.current = zoom;
      setCursor('ew-resize');
      return;
    }

    setIsDragging(true);
    dragStart.current = { x, y };
    dragOffsetStart.current = { ...scrollOffset };
    setCursor('grabbing');
  };

  const handleMouseMove = (e) => {
    const rect = canvasRef.current.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    // Cursor hover logic
    if (!isDragging && !isDraggingAxis.current && !isDraggingTimeAxis.current) {
      const chartH = rect.height - 100;
      if (x > rect.width - axisWidth) setCursor('ns-resize');
      else if (y > chartH) setCursor('ew-resize');
      else setCursor('grab');
    }

    // Price axis drag → adjust stepMultiplier
    if (isDraggingAxis.current && onStepChange) {
      const dy = y - axisDragStartY.current; // inverted: drag down = zoom in (larger step)
      const sensitivity = 4;
      const newStep = Math.max(25, Math.round((axisDragStartStep.current + dy * sensitivity) / 25) * 25);
      onStepChange(newStep);
      return;
    }

    // Time axis drag → adjust horizontal zoom
    if (isDraggingTimeAxis.current) {
      const dx = x - timeAxisDragStartX.current;
      const sensitivity = 0.005;
      const newZoom = Math.max(0.1, Math.min(3.0, timeAxisDragStartZoom.current + dx * sensitivity));
      setZoom(newZoom);
      return;
    }

    if (!isDragging) return;

    const dx = x - dragStart.current.x;
    const dy = y - dragStart.current.y;

    setScrollOffset({
      x: dragOffsetStart.current.x + dx,
      y: dragOffsetStart.current.y + dy
    });
  };

  const handleMouseUp = () => {
    setIsDragging(false);
    isDraggingAxis.current = false;
    isDraggingTimeAxis.current = false;
    setCursor('grab');
  };

  // Wheel interaction for scrolling and zooming
  const handleWheel = (e) => {
    if (e.ctrlKey) {
      // Zoom in/out
      if (e.deltaY < 0) {
        setZoom(z => Math.min(2.5, z + 0.1));
      } else {
        setZoom(z => Math.max(0.3, z - 0.1));
      }
      return;
    }
    // shift + wheel = horizontal scroll, normal wheel = vertical scroll
    if (e.shiftKey) {
      setScrollOffset(prev => ({ ...prev, x: prev.x - e.deltaY }));
    } else {
      setScrollOffset(prev => ({ ...prev, y: prev.y - e.deltaY * 0.5 }));
    }
  };

  return (
    <div className="relative w-full h-full select-none overflow-hidden rounded-xl border border-slate-800 bg-darkBg shadow-2xl" style={{ cursor }}>
      <canvas
        ref={canvasRef}
        className="w-full h-full block"
        onMouseDown={handleMouseDown}
        onMouseMove={handleMouseMove}
        onMouseUp={handleMouseUp}
        onMouseLeave={handleMouseUp}
        onWheel={handleWheel}
      />
      <div className="absolute bottom-4 left-4 flex gap-2 items-center bg-darkBg/50 p-2 rounded-xl backdrop-blur-md border border-slate-800">
        <button
          onClick={() => setZoom(z => Math.max(0.3, z - 0.1))}
          className="w-8 h-8 flex items-center justify-center bg-darkPanel border border-slate-700 rounded-lg text-lg font-bold text-slate-300 hover:text-white hover:bg-slate-800 transition"
          title="Zoom Out"
        >
          -
        </button>
        <span className="text-xs font-mono text-slate-400 min-w-[35px] text-center">
          {Math.round(zoom * 100)}%
        </span>
        <button
          onClick={() => setZoom(z => Math.min(2.5, z + 0.1))}
          className="w-8 h-8 flex items-center justify-center bg-darkPanel border border-slate-700 rounded-lg text-lg font-bold text-slate-300 hover:text-white hover:bg-slate-800 transition"
          title="Zoom In"
        >
          +
        </button>
        
        <div className="w-px h-6 bg-slate-700 mx-1"></div>

        <button
          onClick={() => { setScrollOffset({ x: 50, y: 0 }); setZoom(1); }}
          className="px-4 py-1.5 bg-darkPanel border border-slate-700 rounded-lg text-xs font-semibold text-slate-300 hover:text-white hover:bg-slate-800 transition"
        >
          Reset View
        </button>
      </div>
    </div>
  );
}
