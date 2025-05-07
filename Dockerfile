FROM ghcr.io/astral-sh/uv:bookworm-slim AS builder

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_INSTALL_DIR=/python \
    UV_PYTHON_PREFERENCE=only-managed

# Install build dependencies and clean up in the same layer
RUN apt-get update -y && \
    apt-get install --no-install-recommends -y clang git && \
    rm -rf /var/lib/apt/lists/*

# Install Python before the project for caching
RUN uv python install 3.13

WORKDIR /app
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-install-project --no-dev
COPY . /app
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev

FROM debian:bookworm-slim AS runtime

# Set non-interactive installation
ENV DEBIAN_FRONTEND=noninteractive
# Set display for X11
ENV DISPLAY=:0
# Set environment for D-Bus
ENV DBUS_SESSION_BUS_ADDRESS=unix:path=/var/run/dbus/system_bus_socket

# Install required packages including Chromium and clean up in the same layer
RUN apt-get update && \
    apt-get install -y \
    wget \
    gnupg2 \
    git \
    x11vnc \
    xvfb \
    dbus \
    dbus-x11 \
    ca-certificates \
    openbox \
    pulseaudio \
    net-tools \
    nodejs \
    npm \
    fonts-freefont-ttf \
    fonts-ipafont-gothic \
    fonts-wqy-zenhei \
    fonts-thai-tlwg \
    fonts-kacst \
    fonts-symbola \
    fonts-noto-color-emoji && \
    npm i -g proxy-login-automator

# Copy only necessary files from builder
COPY --from=builder /python /python
COPY --from=builder /app /app
# Set proper permissions
RUN chmod -R 755 /python /app

# install Chromium dependencies
RUN wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | apt-key add - \
    && echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-chrome-stable \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /var/cache/apt/*

ENV PATH="/app/.venv/bin:$PATH" \
    CHROME_BIN=/usr/bin/google-chrome \
    CHROMIUM_FLAGS="--display=:0 --no-sandbox --disable-dev-shm-usage --disable-gpu --disable-software-rasterizer --remote-debugging-port=9222 --disable-setuid-sandbox"

# Install noVNC for HTTP access to VNC
RUN git clone --depth 1 https://github.com/novnc/noVNC.git /opt/novnc \
    && git clone --depth 1 https://github.com/novnc/websockify /opt/novnc/utils/websockify

# Create the startup script
RUN echo '#!/bin/bash\n\
mkdir ~/.vnc && x11vnc -storepasswd 1234 ~/.vnc/passwd\n\
# Start system bus\n\
mkdir -p /var/run/dbus\n\
/usr/bin/dbus-daemon --system --nofork --nopidfile &\n\
sleep 1\n\
\n\
# Start session bus\n\
/usr/bin/dbus-daemon --session --nofork --print-address 2 --nopidfile &\n\
sleep 1\n\
\n\
# Start Xvfb\n\
Xvfb :0 -screen 0 1920x1080x24 &\n\
sleep 2\n\
\n\
# Start window manager\n\
openbox &\n\
\n\
# Start VNC server\n\
x11vnc -display :0 -usepw -forever &\n\
\n\
# Start noVNC web server\n\
/opt/novnc/utils/novnc_proxy --vnc localhost:5900 --listen 6080 &\n\
\n\
proxy-login-automator && python /app/server --port 8000 &\n\
# Start Chrome with appropriate flags\n\
google-chrome --display=:0 --no-sandbox --disable-dev-shm-usage --disable-gpu --disable-software-rasterizer --remote-debugging-address=0.0.0.0 --remote-debugging-port=9222\n\
' > /app/boot.sh \
    && chmod +x /app/boot.sh

# Combine VNC setup commands to reduce layers
# RUN mkdir -p ~/.vnc && \
#     printf '#!/bin/sh\nunset SESSION_MANAGER\nunset DBUS_SESSION_BUS_ADDRESS\nstartxfce4' > /root/.vnc/xstartup && \
#     chmod +x /root/.vnc/xstartup && \
#     printf '#!/bin/bash\n\n# Use Docker secret for VNC password if available, else fallback to default\nif [ -f "/run/secrets/vnc_password" ]; then\n  cat /run/secrets/vnc_password | vncpasswd -f > /root/.vnc/passwd\nelse\n  cat /run/secrets/vnc_password_default | vncpasswd -f > /root/.vnc/passwd\nfi\n\nchmod 600 /root/.vnc/passwd\nvncserver -depth 24 -geometry 1920x1080 -localhost no -PasswordFile /root/.vnc/passwd :0\nproxy-login-automator\npython /app/server --port 8000' > /app/boot.sh && \
#     chmod +x /app/boot.sh

RUN playwright install --with-deps --no-shell chromium

EXPOSE 8000 5900 9222 6080

ENTRYPOINT ["/bin/bash", "/app/boot.sh"]
