class AlertEngine {
  constructor() {
    this.processedClusters = new Set();
    this.audioCache = {};
    
    // We could load actual mp3/wav files here. For this implementation,
    // we'll use the browser's SpeechSynthesis API as a fallback to actually say the alert out loud,
    // which is very useful for trading without looking at the screen.
  }

  playAudio(message) {
    if ('speechSynthesis' in window) {
      const msg = new SpeechSynthesisUtterance(message);
      msg.rate = 1.2;
      msg.pitch = 1.1;
      window.speechSynthesis.speak(msg);
    } else {
      console.log('Audio Alert:', message);
    }
  }

  processClusters(clusters, pushToast) {
    if (!clusters || clusters.length === 0) return;

    const fiveMinutesAgo = Date.now() - 5 * 60 * 1000;

    clusters.forEach(cluster => {
      // Only alert on closed clusters that we haven't processed yet
      if (cluster.status === 'closed' && cluster.open_time && !this.processedClusters.has(cluster.open_time)) {
        this.processedClusters.add(cluster.open_time);

        // Skip historical clusters — only alert for recent data
        if (cluster.open_time < fiveMinutesAgo) return;
        
        const adv = cluster.advanced_metrics;
        if (!adv) return;
        
        let alerts = [];

        // 1. P/B Pattern Alerts
        if (adv.pattern === 'P') {
          alerts.push({ type: 'info', msg: 'P Pattern Detected (Possible Short Covering)' });
        } else if (adv.pattern === 'B') {
          alerts.push({ type: 'info', msg: 'B Pattern Detected (Possible Long Liquidation)' });
        }

        // 2. Exhaustion/Absorption Alerts
        if (adv.top_extreme === 'absorption') {
           alerts.push({ type: 'warning', msg: 'Heavy Absorption at the Highs!' });
        } else if (adv.top_extreme === 'exhaustion') {
           alerts.push({ type: 'info', msg: 'Exhaustion at the Highs.' });
        }
        
        if (adv.bottom_extreme === 'absorption') {
           alerts.push({ type: 'warning', msg: 'Heavy Absorption at the Lows!' });
        } else if (adv.bottom_extreme === 'exhaustion') {
           alerts.push({ type: 'info', msg: 'Exhaustion at the Lows.' });
        }

        // 3. Divergence Alerts
        if (adv.delta_divergence) {
           alerts.push({ type: 'error', msg: 'Delta Divergence! Price moving against Order Flow.' });
        }
        
        // 4. Ratio Extremes
        if (adv.high_ratio && adv.high_ratio < 0.5) {
           alerts.push({ type: 'warning', msg: `High Ratio Alert: ${adv.high_ratio}` });
        }
        if (adv.low_ratio && adv.low_ratio < 0.5) {
           alerts.push({ type: 'warning', msg: `Low Ratio Alert: ${adv.low_ratio}` });
        }

        // Dispatch alerts
        if (alerts.length > 0) {
          // Play highest priority audio
          const hasWarning = alerts.some(a => a.type === 'warning' || a.type === 'error');
          if (hasWarning) {
            this.playAudio(alerts[0].msg);
          }
          
          // Push UI toasts
          if (pushToast) {
            alerts.forEach(a => pushToast(a.msg, a.type));
          }
        }
      }
    });
  }
}

export default new AlertEngine();
