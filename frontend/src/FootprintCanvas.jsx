import React, { useRef, useEffect, useState } from 'react';

export default function FootprintCanvas({ clusters, tickSize = 1.0, stepMultiplier = 1, viewMode = 'bidask', imbalanceRatio = 300 }) {
  const canvasRef = useRef(null);
  
  // Navigation & Scale State
  const [scrollOffset, setScrollOffset] = useState({ x: 50, y: 0 }); // X: horizontal offset, Y: vertical offset
  const [zoom, setZoom] = useState(1); // Zoom level
  const [isDragging, setIsDragging] = useState(false);
  const dragStart = useRef({ x: 0, y: 0 });
  const dragOffsetStart = useRef({ x: 0, y: 0 });
  
  // Apply zoom to sizes
  const colWidth = 140 * zoom; // width of each cluster column
  const colGap = 15 * zoom;    // gap between columns
  const rowHeight = 26 * zoom; // height of each price cell
  const axisWidth = 70; // width of the vertical price axis on the right

  // Handle auto-scroll to the right (most recent cluster) on new cluster load
  const lastClusterCount = useRef(0);
  useEffect(() => {
    if (clusters && clusters.length > lastClusterCount.current && canvasRef.current) {
      const canvas = canvasRef.current;
      // Scroll to show the active cluster at the right side
      const rightmostX = canvas.width - axisWidth - (clusters.length * (colWidth + colGap)) - 50;
      setScrollOffset(prev => ({ ...prev, x: Math.min(160, rightmostX) }));
      lastClusterCount.current = clusters.length;
    }
  }, [clusters?.length]);

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

    // Cumulative Delta Tracking
    let cumulativeDelta = 0;

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

      // Draw Cluster Header (Info Card at the top)
      const headerY = getPriceY(highestPrice) - rowHeight - 35;
      
      // Header Background
      ctx.fillStyle = 'rgba(21, 27, 38, 0.85)';
      ctx.strokeStyle = cluster.status === 'active' ? 'rgba(0, 230, 118, 0.4)' : '#2A364F';
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.roundRect(colX, headerY, colWidth, 45, 6);
      ctx.fill();
      ctx.stroke();

      // Header Text
      ctx.fillStyle = '#94A3B8';
      ctx.font = '10px JetBrains Mono, monospace';
      ctx.textAlign = 'left';
      
      const pattern = cluster.advanced_metrics?.pattern;
      const divergence = cluster.advanced_metrics?.delta_divergence;
      
      let patternTag = '';
      if (pattern === 'P') patternTag = '[P] ';
      if (pattern === 'B') patternTag = '[B] ';
      
      // Divergence Tag
      if (divergence) patternTag += '⚠️ ';
      
      // Volume & Delta
      const volK = (cluster.total_volume || 0).toFixed(0);
      const deltaStr = (cluster.total_delta >= 0 ? '+' : '') + (cluster.total_delta || 0).toFixed(0);
      
      ctx.fillText(`${patternTag}VOL: ${volK}`, colX + 8, headerY + 18);
      ctx.fillStyle = cluster.total_delta >= 0 ? '#00E676' : '#FF1744';
      ctx.fillText(`DEL: ${deltaStr}`, colX + 8, headerY + 32);

      // Time or reason
      ctx.fillStyle = '#64748B';
      const timeStr = cluster.open_time ? new Date(cluster.open_time).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '--:--:--';
      ctx.fillText(timeStr, colX + colWidth - 55, headerY + 18);

      // Find max volume in this cluster to calculate relative opacities
      const maxTotalVolumeInCluster = Math.max(...Object.values(levels).map(l => l.total || 1));

      // OHLC Candlestick Skeleton (Background)
      if (cluster.open_price !== undefined && cluster.close_price !== undefined) {
         const isBull = cluster.close_price >= cluster.open_price;
         ctx.strokeStyle = isBull ? 'rgba(0, 230, 118, 0.4)' : 'rgba(255, 23, 68, 0.4)';
         ctx.fillStyle = isBull ? 'rgba(0, 230, 118, 0.1)' : 'rgba(255, 23, 68, 0.1)';
         ctx.lineWidth = 1;
         const openY = getPriceY(cluster.open_price);
         const closeY = getPriceY(cluster.close_price);
         const highY = getPriceY(highestPrice);
         const lowY = getPriceY(lowestPrice);
         
         const candleTop = Math.min(openY, closeY) - rowHeight / 2;
         const candleBottom = Math.max(openY, closeY) + rowHeight / 2;
         const bodyHeight = Math.max(2, candleBottom - candleTop);
         
         // Draw Wick (Pavio)
         ctx.beginPath();
         ctx.moveTo(colX + colWidth / 2, highY - rowHeight / 2);
         ctx.lineTo(colX + colWidth / 2, lowY + rowHeight / 2);
         ctx.stroke();
         
         // Draw Body Background
         ctx.fillRect(colX - 4, candleTop, colWidth + 8, bodyHeight);
         ctx.strokeRect(colX - 4, candleTop, colWidth + 8, bodyHeight);
      }

      // Draw Cells
      pricesStr.forEach((priceStr, i) => {
        const price = Number(priceStr);
        const cellData = levels[priceStr];
        const cellY = getPriceY(price) - rowHeight / 2;
        
        // Skip if vertically out of bounds
        if (cellY + rowHeight < 0 || cellY > height) return;

        const bid = cellData.bid || 0;
        const ask = cellData.ask || 0;
        const total = cellData.total || 0;
        
        // Dynamic Imbalance Calculation (Frontend)
        const ratio = imbalanceRatio / 100.0;
        let dynImbalance = null;
        
        // ask vs lower bid
        const lowerData = i + 1 < pricesStr.length ? levels[pricesStr[i + 1]] : null;
        const lowerBid = lowerData ? (lowerData.bid || 0) : 0;
        const isBuyImbalance = ask >= lowerBid * ratio && ask > 0;
        
        // bid vs higher ask
        const upperData = i - 1 >= 0 ? levels[pricesStr[i - 1]] : null;
        const upperAsk = upperData ? (upperData.ask || 0) : 0;
        const isSellImbalance = bid >= upperAsk * ratio && bid > 0;
        
        if (isBuyImbalance && isSellImbalance) dynImbalance = 'both';
        else if (isBuyImbalance) dynImbalance = 'buy';
        else if (isSellImbalance) dynImbalance = 'sell';

        // Volume-based opacity
        const relOpacity = maxTotalVolumeInCluster > 0 ? (total / maxTotalVolumeInCluster) : 0;
        
        // Base fill color with opacity
        let cellColor = `rgba(59, 130, 246, ${0.05 + relOpacity * 0.25})`; // Dark Slate Blue default
        if (ask >= bid * ratio && ask > 0) {
           cellColor = `rgba(0, 230, 118, ${0.2 + relOpacity * 0.5})`; // Strong Green Heatmap (Horizontal)
        } else if (bid >= ask * ratio && bid > 0) {
           cellColor = `rgba(255, 23, 68, ${0.2 + relOpacity * 0.5})`; // Strong Red Heatmap (Horizontal)
        } else if (dynImbalance === 'buy') {
           cellColor = `rgba(0, 230, 118, ${0.1 + relOpacity * 0.35})`; // Neon Green tint
        } else if (dynImbalance === 'sell') {
           cellColor = `rgba(255, 23, 68, ${0.1 + relOpacity * 0.35})`;  // Neon Red tint
        } else if (dynImbalance === 'both') {
           cellColor = `rgba(168, 85, 247, ${0.1 + relOpacity * 0.35})`; // Purple
        }

        ctx.fillStyle = cellColor;
        ctx.fillRect(colX, cellY, colWidth, rowHeight - 2);

        // Imbalance border outline
        if (dynImbalance === 'buy') {
          ctx.strokeStyle = 'rgba(0, 230, 118, 0.8)';
          ctx.lineWidth = 1;
          ctx.strokeRect(colX + 0.5, cellY + 0.5, colWidth - 1, rowHeight - 3);
        } else if (dynImbalance === 'sell') {
          ctx.strokeStyle = 'rgba(255, 23, 68, 0.8)';
          ctx.lineWidth = 1;
          ctx.strokeRect(colX + 0.5, cellY + 0.5, colWidth - 1, rowHeight - 3);
        }

        // Draw POC outline (Thick Gold Border)
        if (price === cluster.poc) {
          ctx.strokeStyle = '#FFD600';
          ctx.lineWidth = 2;
          ctx.strokeRect(colX + 1, cellY + 1, colWidth - 2, rowHeight - 4);
        }

        // Draw Text (Bid x Ask OR Delta)
        const fontSize = Math.max(6, 11 * zoom);
        ctx.font = `${fontSize}px JetBrains Mono, monospace`;
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        
        if (dynImbalance === 'buy') {
          ctx.fillStyle = '#00E676';
        } else if (dynImbalance === 'sell') {
          ctx.fillStyle = '#FF1744';
        } else {
          ctx.fillStyle = '#E2E8F0';
        }
        
        // Hide text if zoomed out too much to avoid clutter
        if (zoom >= 0.5) {
          if (viewMode === 'delta') {
            const deltaStr = (cellData.delta >= 0 ? '+' : '') + (cellData.delta || 0).toFixed(0);
            ctx.fillText(deltaStr, colX + colWidth / 2, cellY + rowHeight / 2);
          } else {
            ctx.fillText(`${bid.toFixed(0)} × ${ask.toFixed(0)}`, colX + colWidth / 2, cellY + rowHeight / 2);
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

      // Calculate Cumulative Delta for bottom panel
      cumulativeDelta += (cluster.total_delta || 0);
      
      // Bottom Panel (Delta Histogram)
      const panelY = height - bottomPanelHeight;
      const cvdBaseline = panelY + bottomPanelHeight / 2;
      
      // Delta cluster bar
      const deltaVol = cluster.total_delta || 0;
      const deltaColor = deltaVol >= 0 ? 'rgba(0, 230, 118, 0.7)' : 'rgba(255, 23, 68, 0.7)';
      ctx.fillStyle = deltaColor;
      
      // Scale: 1000 volume = 20px
      const scaleFactor = 30 / 1000; 
      const barH = Math.min(Math.abs(deltaVol) * scaleFactor, bottomPanelHeight / 2 - 5);
      const startY = deltaVol >= 0 ? cvdBaseline - barH : cvdBaseline;
      ctx.fillRect(colX + 5, startY, colWidth - 10, barH);
      
      // CVD line (Cumulative Delta)
      ctx.fillStyle = cumulativeDelta >= 0 ? '#00E676' : '#FF1744';
      ctx.font = '10px JetBrains Mono, monospace';
      ctx.fillText(`CVD: ${cumulativeDelta.toFixed(0)}`, colX + colWidth / 2, panelY + 15);
      
    });

    // Draw Volume Profile Overlay Panel (Left Side)
    const volProfileWidth = 140;
    const volumeProfile = {};
    let maxProfileVolume = 0;
    clusters.forEach(cluster => {
      const lvls = cluster.levels || {};
      Object.keys(lvls).forEach(pStr => {
        const p = parseFloat(pStr);
        const data = lvls[pStr];
        const binPrice = Math.round(p / actualTickSize) * actualTickSize;
        volumeProfile[binPrice] = (volumeProfile[binPrice] || 0) + (data.total || 0);
        if (volumeProfile[binPrice] > maxProfileVolume) {
          maxProfileVolume = volumeProfile[binPrice];
        }
      });
    });
    
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
      });
      
      // Panel Title
      ctx.fillStyle = '#94A3B8';
      ctx.font = '10px JetBrains Mono, monospace';
      ctx.textAlign = 'center';
      ctx.fillText('VOL PROFILE', volProfileWidth / 2, 20);
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

    // Render price tags along the axis
    ctx.fillStyle = '#94A3B8';
    ctx.font = '10px JetBrains Mono, monospace';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'middle';

    // Step every rowHeight
    const startY = 0;
    const endY = chartHeight;
    
    // Draw tick labels on axis
    for (let y = startY; y < endY; y += rowHeight) {
      const price = getYPrice(y);
      // Align price to tickSize
      const roundedPrice = Math.round(price / tickSize) * tickSize;
      const labelY = getPriceY(roundedPrice);
      
      // Draw grid line connection to axis
      ctx.strokeStyle = 'rgba(30, 41, 59, 0.5)';
      ctx.lineWidth = 0.5;
      ctx.beginPath();
      ctx.moveTo(0, labelY);
      ctx.lineTo(width - axisWidth, labelY);
      ctx.stroke();
      
      const decimals = tickSize < 1 ? Math.max(0, -Math.floor(Math.log10(tickSize))) : 2;
      ctx.fillStyle = '#64748B';
      ctx.fillText(`${roundedPrice.toFixed(decimals)}`, width - axisWidth + 8, labelY);
    }
    
    // Bottom Panel separator
    const panelY = height - bottomPanelHeight;
    ctx.fillStyle = '#111827';
    ctx.fillRect(0, panelY, width, bottomPanelHeight);
    
    ctx.strokeStyle = '#1E293B';
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(0, panelY);
    ctx.lineTo(width, panelY);
    ctx.stroke();
    
    // Draw CVD zero line
    const cvdBaseline = panelY + bottomPanelHeight / 2;
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.1)';
    ctx.lineWidth = 1;
    ctx.setLineDash([5, 5]);
    ctx.beginPath();
    ctx.moveTo(0, cvdBaseline);
    ctx.lineTo(width, cvdBaseline);
    ctx.stroke();
    ctx.setLineDash([]);
    
    // CVD Label
    ctx.fillStyle = '#94A3B8';
    ctx.font = '12px Outfit, sans-serif';
    ctx.textAlign = 'right';
    ctx.fillText('CVD / Delta', width - 20, panelY + 20);

  }, [clusters, scrollOffset]);

  // Mouse Interaction: Panning/Scrolling
  const handleMouseDown = (e) => {
    const rect = canvasRef.current.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    
    setIsDragging(true);
    dragStart.current = { x, y };
    dragOffsetStart.current = { ...scrollOffset };
  };

  const handleMouseMove = (e) => {
    if (!isDragging) return;
    const rect = canvasRef.current.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    
    const dx = x - dragStart.current.x;
    const dy = y - dragStart.current.y;
    
    setScrollOffset({
      x: dragOffsetStart.current.x + dx,
      y: dragOffsetStart.current.y + dy
    });
  };

  const handleMouseUp = () => {
    setIsDragging(false);
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
    <div className="relative w-full h-full cursor-grab active:cursor-grabbing select-none overflow-hidden rounded-xl border border-slate-800 bg-darkBg shadow-2xl">
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
