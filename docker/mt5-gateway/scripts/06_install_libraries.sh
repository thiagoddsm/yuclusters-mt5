#!/bin/bash
set -e

echo "=== Installing Python Libraries via Wine ==="
# Ensure pip is up to date
WINEPREFIX=$HOME/.wine wine python -m pip install --upgrade pip

# Install Flask and MetaTrader5
# The user explicitly warned to be careful with the case sensitivity of MetaTrader5!
WINEPREFIX=$HOME/.wine wine python -m pip install Flask MetaTrader5

echo "Libraries installed successfully."
