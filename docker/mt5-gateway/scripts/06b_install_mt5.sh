#!/bin/bash
set -e

echo "=== Downloading and Installing MetaTrader 5 ==="
export WINEPREFIX=$HOME/.wine
export WINEDLLOVERRIDES="mscoree,mshtml="

# Start Xvfb temporarily for the installation 
# Some silent Windows installers still crash if there's no display available
Xvfb :99 -screen 0 1024x768x16 &
XVFB_PID=$!
export DISPLAY=:99
sleep 2

# Download MT5 setup from MetaQuotes official CDN
wget -O mt5setup.exe "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe"

# Install silently ( /auto )
echo "Installing MT5 silently (this may take a minute)..."
wine mt5setup.exe /auto

# Wait for background installation tasks to complete and shutdown Wine safely
wineserver -w
kill $XVFB_PID || true
rm mt5setup.exe

echo "MT5 installed successfully."
