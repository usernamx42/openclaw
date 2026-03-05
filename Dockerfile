FROM node:22-bookworm@sha256:cd7bcd2e7a1e6f72052feb023c7f6b722205d3fcab7bbcbd2d1bfdab10b1e935

# Cache bust for Star Office integration (2026-03-05)
ARG STAR_OFFICE_VERSION=1

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# Install Python + Star Office UI dependencies
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      python3 python3-pip git && \
    pip3 install --no-cache-dir --break-system-packages flask==3.0.2 pillow==10.4.0 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Clone Star Office UI and patch known bugs
RUN git clone --depth 1 https://github.com/ringhyacinth/Star-Office-UI.git /opt/star-office && \
    python3 -c "p='/opt/star-office/frontend/index.html'; t=open(p).read(); bad='                    } else {\n                        if (!typewriterTarget || typewriterTarget !== nextLine) {\n                            typewriterTarget = nextLine;\n                            typewriterText = \"\";\n                            typewriterIndex = 0;\n                        }\n                        }\n'; open(p,'w').write(t.replace(bad,'')) if bad in t else None" && \
    python3 -c "p='/opt/star-office/backend/app.py'; t=open(p).read(); open(p,'w').write(t.replace('data = request.get_json()\n        if not isinstance(data, dict):', 'data = request.get_json(force=True, silent=True)\n        if not isinstance(data, dict):'))" && \
    chown -R node:node /opt/star-office

RUN corepack enable

WORKDIR /app
RUN chown node:node /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

COPY --chown=node:node package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY --chown=node:node ui/package.json ./ui/package.json
COPY --chown=node:node patches ./patches
COPY --chown=node:node scripts ./scripts

USER node
# Reduce OOM risk on low-memory hosts during dependency installation.
# Docker builds on small VMs may otherwise fail with "Killed" (exit 137).
RUN NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile

# Optionally install Chromium and Xvfb for browser automation.
# Build with: docker build --build-arg OPENCLAW_INSTALL_BROWSER=1 ...
# Adds ~300MB but eliminates the 60-90s Playwright install on every container start.
# Must run after pnpm install so playwright-core is available in node_modules.
USER root
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
      mkdir -p /home/node/.cache/ms-playwright && \
      PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright \
      node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
      chown -R node:node /home/node/.cache/ms-playwright && \
      apt-get clean && \
      rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
    fi

USER node
COPY --chown=node:node . .
RUN pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# Expose the CLI binary without requiring npm global writes as non-root.
USER root
RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw \
 && chmod 755 /app/openclaw.mjs

ENV NODE_ENV=production

# Security hardening: Run as non-root user
# The node:22-bookworm image includes a 'node' user (uid 1000)
# This reduces the attack surface by preventing container escape via root privileges
USER node

# Prepare volume mount point so Railway/Docker volumes are writable by node user.
# The entrypoint fixes ownership then drops to node via exec su.
USER root
COPY --chmod=755 <<'ENTRY' /usr/local/bin/docker-entrypoint.sh
#!/bin/sh
set -e
# Fix volume permissions if /data exists and is root-owned
if [ -d /data ] && [ "$(stat -c %u /data)" = "0" ]; then
  chown node:node /data
fi
mkdir -p /data/.openclaw /data/workspace \
  /data/workspace-aidar /data/workspace-igor \
  /data/workspace-aisana /data/workspace-alibek \
  /data/workspace-maria 2>/dev/null || true
chown -R node:node /data/.openclaw /data/workspace \
  /data/workspace-aidar /data/workspace-igor \
  /data/workspace-aisana /data/workspace-alibek \
  /data/workspace-maria 2>/dev/null || true

# Set up Star Office UI persistent state on /data volume
mkdir -p /data/star-office 2>/dev/null || true
if [ ! -f /data/star-office/state.json ]; then
  cp /opt/star-office/state.sample.json /data/star-office/state.json
fi
if [ ! -f /data/star-office/join-keys.json ]; then
  cp /opt/star-office/join-keys.sample.json /data/star-office/join-keys.json 2>/dev/null || true
fi
if [ ! -f /data/star-office/runtime-config.json ]; then
  cp /opt/star-office/runtime-config.sample.json /data/star-office/runtime-config.json 2>/dev/null || true
fi
# Symlink state files so Star Office reads from /data
ln -sf /data/star-office/state.json /opt/star-office/state.json
ln -sf /data/star-office/join-keys.json /opt/star-office/join-keys.json
ln -sf /data/star-office/runtime-config.json /opt/star-office/runtime-config.json
chown -R node:node /data/star-office

# Inject star-office plugin config if not already present
if [ -f /data/.openclaw/openclaw.json ]; then
  node -e "
    var f='/data/.openclaw/openclaw.json';
    var c=JSON.parse(require('fs').readFileSync(f,'utf8'));
    if(!c.plugins) c.plugins={};
    if(!c.plugins['star-office']) {
      c.plugins['star-office']={stateFile:'/data/star-office/state.json'};
      require('fs').writeFileSync(f,JSON.stringify(c,null,2));
    }
  " 2>/dev/null || true
fi

# Start Star Office UI in background
STAR_BACKEND_PORT="${STAR_OFFICE_PORT:-18791}" \
  su -s /bin/sh node -c "python3 /opt/star-office/backend/app.py &"

# Seed default config on first boot only. Once seeded, the user/setup
# wizard owns the file — never overwrite it on subsequent restarts.
if [ ! -f /data/.openclaw/openclaw.json ]; then
  ORIGIN=""
  if [ -n "$RAILWAY_PUBLIC_DOMAIN" ]; then
    ORIGIN="https://$RAILWAY_PUBLIC_DOMAIN"
  fi
  node -e "
    var c={agents:{defaults:{model:{primary:'anthropic/claude-sonnet-4-20250514'}},list:[
      {id:'aidar','default':true,name:'Aidar',workspace:'/data/workspace-aidar',identity:{name:'Aidar',emoji:'\ud83d\udd27',theme:'Tech Lead & AI Architect'}},
      {id:'igor',name:'Igor',workspace:'/data/workspace-igor',identity:{name:'Igor',emoji:'\ud83d\udee1\ufe0f',theme:'DevSecOps & Security Specialist'}},
      {id:'aisana',name:'Aisana',workspace:'/data/workspace-aisana',identity:{name:'Aisana',emoji:'\ud83c\udfa8',theme:'UI/UX Designer'}},
      {id:'alibek',name:'Alibek',workspace:'/data/workspace-alibek',identity:{name:'Alibek',emoji:'\u2705',theme:'QA Lead & Testing Specialist'}},
      {id:'maria',name:'Maria',workspace:'/data/workspace-maria',identity:{name:'Maria',emoji:'\ud83d\udcc8',theme:'Marketing Lead & GTM Strategist'}}
    ]},commands:{native:'auto',nativeSkills:'auto',restart:true,ownerDisplay:'raw'},
    channels:{telegram:{enabled:true,dmPolicy:'allowlist',allowFrom:[439388150],groupPolicy:'open',streaming:'off'}},
    bindings:[{agentId:'aidar',comment:'Default Telegram to Aidar',match:{channel:'telegram'}}],
    gateway:{auth:{mode:'token'},trustedProxies:['100.64.0.0/10','10.0.0.0/8','172.16.0.0/12'],
    controlUi:{allowedOrigins:['${ORIGIN}'],dangerouslyDisableDeviceAuth:true}}};
    require('fs').writeFileSync('/data/.openclaw/openclaw.json',JSON.stringify(c,null,2));
  "
  chown node:node /data/.openclaw/openclaw.json
fi

exec su -s /bin/sh node -c "$*"
ENTRY
ENTRYPOINT ["docker-entrypoint.sh"]

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
