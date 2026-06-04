# YuClusters Local 📊

YuClusters Local is a professional footprint chart and volumetric cluster analyzer integrated directly with your local **MetaTrader 5 (MT5)** terminal.

## Key Features

- **Real-Time Footprint Charting**: Ticks polled at ~100ms intervals and visualised dynamically using an optimized HTML5 Canvas element.
- **Diagonal Imbalances Detection**: Identifies aggressive buying or selling imbalances ($R \ge 3.0$).
- **Stacked Imbalances Highlights**: Dynamically spots 3+ consecutive imbalances in the same direction.
- **POC Highlight**: Identifies and highlights the highest volume nodes within each cluster using a gold border.
- **Interactive Drag & Pan UI**: Fully-featured HTML5 Canvas dashboard with drag-to-scroll horizontal/vertical panning and zoom adjustment.

---

## Installation & Setup

### 1. Prerequisites
- **Windows OS** (required by MetaTrader 5 API)
- **MetaTrader 5 Terminal** running locally and logged into your broker account
- **Python 3.11+** installed and added to PATH
- **Node.js 18+** installed

### 2. Backend Installation

1. From the project root, install Python dependencies:
   ```powershell
   pip install -r requirements.txt
   ```
2. Set your environment configurations in `config/settings.py` or export them as environment variables (e.g. `MT5_LOGIN`, `MT5_PASSWORD`, `MT5_SERVER`).

### 3. Frontend Installation

1. Navigate to the `frontend/` folder:
   ```powershell
   cd frontend
   ```
2. Install npm packages:
   ```powershell
   npm install
   ```

---

## Execution Guide

### 1. Run the Backend Server
Start the FastAPI server (this will automatically launch the MetaTrader 5 polling collector):
```powershell
python backend/server.py
```

### 2. Run the React Frontend
Start the Vite development server:
```powershell
cd frontend
npm run dev
```
Open [http://localhost:3000](http://localhost:3000) in your web browser.

---

## Technical Calculations (from SKILL.md)

1. **Diagonal Buy Imbalance**: `ask_vol[i] >= R * bid_vol[i-1]` (compares with price level below)
2. **Diagonal Sell Imbalance**: `bid_vol[i] >= R * ask_vol[i+1]` (compares with price level above)
3. **POC (Point of Control)**: Price level with the highest total volume (`ask_vol + bid_vol`) inside a cluster. If volumes tie, the highest price wins.
4. **Stacked Imbalance Zone**: A vertical zone spanning 3 or more consecutive levels with the same imbalance direction.
