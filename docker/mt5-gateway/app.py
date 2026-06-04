import os
from flask import Flask, jsonify, request
import MetaTrader5 as mt5

app = Flask(__name__)

# Basic settings from environment or defaults
MT5_PATH = os.getenv("MT5_PATH", "C:\\Program Files\\MetaTrader 5\\terminal64.exe")
MT5_SERVER = os.getenv("MT5_SERVER", "")
MT5_LOGIN = int(os.getenv("MT5_LOGIN", "0"))
MT5_PASSWORD = os.getenv("MT5_PASSWORD", "")

def init_mt5():
    # If login is provided, connect with credentials
    if MT5_LOGIN != 0 and MT5_PASSWORD:
        if not mt5.initialize(path=MT5_PATH, login=MT5_LOGIN, server=MT5_SERVER, password=MT5_PASSWORD):
            return False, mt5.last_error()
    else:
        # Just initialize whatever is there
        if not mt5.initialize(path=MT5_PATH):
            return False, mt5.last_error()
    return True, None

@app.route('/health', methods=['GET'])
def health_check():
    success, error = init_mt5()
    if not success:
        return jsonify({"status": "error", "message": "Failed to connect to MT5", "error_code": error}), 500
    
    info = mt5.terminal_info()
    if info is None:
        return jsonify({"status": "error", "message": "Failed to get terminal info"}), 500
        
    return jsonify({
        "status": "ok",
        "terminal_connected": info.connected,
        "trade_allowed": info.trade_allowed,
        "build": info.build
    })

@app.route('/symbol/<ticker>', methods=['GET'])
def symbol_info(ticker):
    init_mt5()
    info = mt5.symbol_info(ticker)
    if info is None:
        return jsonify({"status": "error", "message": f"Symbol {ticker} not found"}), 404
        
    return jsonify({
        "symbol": info.name,
        "bid": info.bid,
        "ask": info.ask,
        "spread": info.spread,
        "trade_mode": info.trade_mode
    })

@app.route('/order', methods=['POST'])
def place_order():
    init_mt5()
    data = request.json
    
    # Very basic order payload (can be extended with full Swagger spec later)
    # Expects: {"symbol": "EURUSD", "action": "buy", "volume": 1.0}
    symbol = data.get("symbol")
    action = data.get("action")
    volume = float(data.get("volume", 0.0))
    
    if action == "buy":
        type = mt5.ORDER_TYPE_BUY
        price = mt5.symbol_info_tick(symbol).ask
    else:
        type = mt5.ORDER_TYPE_SELL
        price = mt5.symbol_info_tick(symbol).bid
        
    order_request = {
        "action": mt5.TRADE_ACTION_DEAL,
        "symbol": symbol,
        "volume": volume,
        "type": type,
        "price": price,
        "deviation": 20,
        "magic": 234000,
        "comment": "python api",
        "type_time": mt5.ORDER_TIME_GTC,
        "type_filling": mt5.ORDER_FILLING_IOC,
    }
    
    result = mt5.order_send(order_request)
    
    if result is None:
        return jsonify({"status": "error", "message": "Order failed entirely", "error": mt5.last_error()}), 500
        
    # Translate MT5 Return Codes to friendly API responses
    # Mapping can be expanded as needed
    if result.retcode == mt5.TRADE_RETCODE_DONE:
        return jsonify({"status": "ok", "retcode": result.retcode, "deal": result.deal, "message": "Order placed successfully"})
    elif result.retcode == mt5.TRADE_RETCODE_MARKET_CLOSED:
        return jsonify({"status": "error", "retcode": result.retcode, "message": "Market is closed"}), 400
    else:
        return jsonify({"status": "error", "retcode": result.retcode, "message": "Order failed", "comment": result.comment}), 400

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
