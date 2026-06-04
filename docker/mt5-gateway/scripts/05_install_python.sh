#!/bin/bash
set -e

echo "=== Installing Python for Windows via Wine ==="
# We need to install the Windows version of Python inside Wine for MT5 library compatibility
WINEPREFIX=$HOME/.wine wine msiexec /i https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.msi /quiet InstallAllUsers=1 PrependPath=1 Include_test=0

# Verify python installation
WINEPREFIX=$HOME/.wine wine python --version
echo "Python installed successfully."
