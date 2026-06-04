FROM ubuntu:22.04

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Add 32-bit architecture for Wine and install dependencies
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    wine64 \
    wine32 \
    xvfb \
    wget \
    cabextract \
    winbind \
    curl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set up user for Wine
RUN useradd -m -s /bin/bash mt5user
USER mt5user
WORKDIR /home/mt5user

# Copy scripts
COPY --chown=mt5user:mt5user scripts/ /app/scripts/
RUN chmod +x /app/scripts/*.sh

# Run provisioning steps
RUN /app/scripts/05_install_python.sh
RUN /app/scripts/06_install_libraries.sh
RUN /app/scripts/06b_install_mt5.sh

# Copy application source
COPY --chown=mt5user:mt5user app.py /app/app.py

EXPOSE 5000

# Start script
ENTRYPOINT ["/app/scripts/07_start_wine_flask.sh"]
