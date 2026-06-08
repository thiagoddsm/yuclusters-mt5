import MetaTrader5 as mt5
import logging

logger = logging.getLogger("trading")

def send_buy_signal():
    """
    Sets the global variable SINAL_PYTHON_COMPRA to 1 in MT5.
    The MQL5 Expert Advisor will detect this, execute the trade, and reset the variable to 0.
    """
    try:
        success = mt5.global_variable_set("SINAL_PYTHON_COMPRA", 1.0)
        if success:
            logger.info("SINAL_PYTHON_COMPRA defined successfully.")
            return True
        else:
            logger.error("Failed to set SINAL_PYTHON_COMPRA.")
            return False
    except Exception as e:
        logger.error(f"Exception when sending BUY signal: {e}")
        return False

def send_sell_signal():
    """
    Sets the global variable SINAL_PYTHON_VENDA to 1 in MT5.
    The MQL5 Expert Advisor will detect this, execute the trade, and reset the variable to 0.
    """
    try:
        success = mt5.global_variable_set("SINAL_PYTHON_VENDA", 1.0)
        if success:
            logger.info("SINAL_PYTHON_VENDA defined successfully.")
            return True
        else:
            logger.error("Failed to set SINAL_PYTHON_VENDA.")
            return False
    except Exception as e:
        logger.error(f"Exception when sending SELL signal: {e}")
        return False
