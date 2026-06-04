#!/bin/bash
set -e

echo "=== Starting MT5 Gateway ==="
export WINEPREFIX=$HOME/.wine
export WINEDLLOVERRIDES="mscoree,mshtml="

# Start Xvfb in background
Xvfb :0 -screen 0 1024x768x16 &
export DISPLAY=:0

# Wait for X11
sleep 2

# We start the Flask server via Python in Wine
# The MT5 logic inside app.py will initialize MT5
echo "Starting Flask API Bridge..."
wine python /app/app.py
