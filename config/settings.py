import os

# MT5
MT5_LOGIN = int(os.environ.get("MT5_LOGIN", 0))           # seu número de conta
MT5_PASSWORD = os.environ.get("MT5_PASSWORD", "")       # sua senha
MT5_SERVER = os.environ.get("MT5_SERVER", "")           # nome do servidor (ex: "XPInvestimentos-Real")
MT5_SYMBOL = os.environ.get("MT5_SYMBOL", "USTEC")       # símbolo padrão

# Cluster
CLUSTER_RANGE_POINTS = float(os.environ.get("CLUSTER_RANGE_POINTS", 50.0))
CLUSTER_VOLUME_MAX = float(os.environ.get("CLUSTER_VOLUME_MAX", 100000))
CLUSTER_DELTA_MAX = float(os.environ.get("CLUSTER_DELTA_MAX", 800))
CLUSTER_TIME_SECONDS = float(os.environ.get("CLUSTER_TIME_SECONDS", 300))
CLUSTER_CLOSE_MODE = os.environ.get("CLUSTER_CLOSE_MODE", "delta")  # "range" | "volume" | "delta" | "time"

# Imbalance & Big Trades
IMBALANCE_RATIO = float(os.environ.get("IMBALANCE_RATIO", 3.0))
STACKED_MIN_COUNT = int(os.environ.get("STACKED_MIN_COUNT", 3))
BIG_TRADE_THRESHOLD = float(os.environ.get("BIG_TRADE_THRESHOLD", 50.0))

# WebSocket
WS_PORT = int(os.environ.get("WS_PORT", 6002))
HISTORY_BUFFER_SIZE = int(os.environ.get("HISTORY_BUFFER_SIZE", 500))
HISTORY_HOURS = float(os.environ.get("HISTORY_HOURS", 4.0))
HISTORY_FROM_DATE = os.environ.get("HISTORY_FROM_DATE", "")  # ex: "2026.06.04" — se definido, ignora HISTORY_HOURS
HISTORY_SESSION_START = os.environ.get("HISTORY_SESSION_START", "true").lower() == "true"  # puxar desde a última abertura de sessão
