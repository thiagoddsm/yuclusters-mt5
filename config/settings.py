import os

# MT5
MT5_LOGIN = int(os.environ.get("MT5_LOGIN", 0))           # seu número de conta
MT5_PASSWORD = os.environ.get("MT5_PASSWORD", "")       # sua senha
MT5_SERVER = os.environ.get("MT5_SERVER", "")           # nome do servidor (ex: "XPInvestimentos-Real")
MT5_SYMBOL = os.environ.get("MT5_SYMBOL", "EURUSD")      # símbolo padrão

# Cluster
CLUSTER_RANGE_POINTS = int(os.environ.get("CLUSTER_RANGE_POINTS", 10))
CLUSTER_VOLUME_MAX = float(os.environ.get("CLUSTER_VOLUME_MAX", 1000))
CLUSTER_DELTA_MAX = float(os.environ.get("CLUSTER_DELTA_MAX", 500))
CLUSTER_TIME_SECONDS = float(os.environ.get("CLUSTER_TIME_SECONDS", 60))
CLUSTER_CLOSE_MODE = os.environ.get("CLUSTER_CLOSE_MODE", "range")  # "range" | "volume" | "delta" | "time"

# Imbalance
IMBALANCE_RATIO = float(os.environ.get("IMBALANCE_RATIO", 3.0))
STACKED_MIN_COUNT = int(os.environ.get("STACKED_MIN_COUNT", 3))

# WebSocket
WS_PORT = int(os.environ.get("WS_PORT", 6002))
HISTORY_BUFFER_SIZE = int(os.environ.get("HISTORY_BUFFER_SIZE", 50))
