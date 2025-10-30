# Use the official uv image as base
FROM ghcr.io/astral-sh/uv:debian AS base

# Copy and install corporate certificate
COPY cert/AMD_CA.crt /usr/local/share/ca-certificates/AMD_CA.crt
RUN chmod 644 /usr/local/share/ca-certificates/AMD_CA.crt

ENV NODE_EXTRA_CA_CERTS="/usr/local/share/ca-certificates/AMD_CA.crt"

# Completely replace sources.list to avoid authentication issues
RUN rm -f /etc/apt/sources.list.d/* && \
    echo "deb http://archive.debian.org/debian/ bullseye main" > /etc/apt/sources.list

# Update package lists and install base packages
RUN apt-get update --allow-releaseinfo-change && APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1 apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    nginx \
    nano \
    sudo \
    build-essential \
    && update-ca-certificates \
    && mkdir -p /etc/apt/keyrings \
    && (curl --cacert /usr/local/share/ca-certificates/AMD_CA.crt -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key || curl -k -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key) | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && node --version \
    && npm --version \
    && npm config set cafile /usr/local/share/ca-certificates/AMD_CA.crt \
    && npm config set strict-ssl false \
    && npm config set registry https://registry.npmjs.org/ \
    && npm install -g pnpm@10.12.0 \
    && pnpm config set strict-ssl false \
    && pnpm config set ca /usr/local/share/ca-certificates/AMD_CA.crt \
    && pnpm --version \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Configure nginx to run as nextjs user with proper permissions
RUN sed -i 's/user www-data;/user nextjs;/' /etc/nginx/nginx.conf && \
    sed -i 's/pid \/run\/nginx.pid;/pid \/tmp\/nginx.pid;/' /etc/nginx/nginx.conf && \
    sed -i 's/error_log \/var\/log\/nginx\/error.log;/error_log \/tmp\/nginx_error.log;/' /etc/nginx/nginx.conf

# Copy our custom server configuration
COPY ./nginx.conf /etc/nginx/sites-available/default
RUN rm -f /etc/nginx/sites-enabled/default && \
    ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# Install dependencies only when needed
FROM base AS deps
WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED 1

# Copy root package files
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY turbo.json ./

# Copy package.json files from all workspaces
COPY apps/frontend/package.json ./apps/frontend/
COPY apps/backend/package.json ./apps/backend/
COPY packages/eslint-config/package.json ./packages/eslint-config/
COPY packages/trpc/package.json ./packages/trpc/
COPY packages/typescript-config/package.json ./packages/typescript-config/
COPY packages/zod-types/package.json ./packages/zod-types/

# Install dependencies
RUN pnpm install --frozen-lockfile

# Builder stage
FROM base AS builder
WORKDIR /app

# Copy node_modules from deps stage
COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/apps/frontend/node_modules ./apps/frontend/node_modules
COPY --from=deps /app/apps/backend/node_modules ./apps/backend/node_modules
COPY --from=deps /app/packages ./packages

# Copy source code
COPY . .

# Build all packages and apps
RUN pnpm build

RUN sed -i -e "s/30000/600000/" \
    "node_modules/.pnpm/next@15.5.2_react-dom@19.1.0_react@19.1.0__react@19.1.0/node_modules/next/dist/server/lib/router-utils/proxy-request.js" \
    "node_modules/.pnpm/next@15.5.2_react-dom@19.1.0_react@19.1.0__react@19.1.0/node_modules/next/dist/esm/server/lib/router-utils/proxy-request.js"

# Production runner stage
FROM base AS runner
WORKDIR /app

# OCI image labels
LABEL org.opencontainers.image.source="https://github.com/metatool-ai/metamcp"
LABEL org.opencontainers.image.description="MetaMCP - aggregates MCP servers into a unified MetaMCP"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.title="MetaMCP"
LABEL org.opencontainers.image.vendor="metatool-ai"

# Install curl for health checks (reuse same repository configuration)
RUN rm -f /etc/apt/sources.list.d/* && \
    echo "deb http://archive.debian.org/debian/ bullseye main" > /etc/apt/sources.list && \
    apt-get update --allow-releaseinfo-change && \
    apt-get install -y --no-install-recommends curl postgresql-client-13 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user with proper home directory
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 --home /home/nextjs nextjs && \
    mkdir -p /home/nextjs/.cache/node/corepack && \
    chown -R nextjs:nodejs /home/nextjs

# Create nginx directories with proper permissions for nextjs user
RUN mkdir -p /var/cache/nginx /tmp/nginx /home/nextjs/logs && \
    chown -R nextjs:nodejs /var/cache/nginx && \
    chown -R nextjs:nodejs /var/log/nginx && \
    chown -R nextjs:nodejs /var/lib/nginx && \
    chown -R nextjs:nodejs /tmp/nginx && \
    chown -R nextjs:nodejs /home/nextjs/logs && \
    chmod 755 /tmp/nginx && \
    chmod 755 /home/nextjs/logs

# Copy built applications
COPY --from=builder --chown=nextjs:nodejs /app/apps/frontend/.next ./apps/frontend/.next
COPY --from=builder --chown=nextjs:nodejs /app/apps/frontend/package.json ./apps/frontend/
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/dist ./apps/backend/dist
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/package.json ./apps/backend/
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/drizzle ./apps/backend/drizzle
COPY --from=builder --chown=nextjs:nodejs /app/apps/backend/drizzle.config.ts ./apps/backend/

# Copy built packages
COPY --from=builder --chown=nextjs:nodejs /app/packages ./packages
COPY --from=builder --chown=nextjs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nextjs:nodejs /app/package.json ./
COPY --from=builder --chown=nextjs:nodejs /app/pnpm-workspace.yaml ./

# Install production dependencies only
RUN pnpm install --prod

# Install drizzle-kit locally in backend for migrations
RUN cd apps/backend && pnpm add drizzle-kit@0.31.1

# Copy startup script
COPY --chown=nextjs:nodejs docker-entrypoint.sh ./
RUN chmod +x docker-entrypoint.sh

USER nextjs

# Expose frontend port (Next.js)
EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=30s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:12008/health || exit 1

# Start both backend and frontend
CMD ["./docker-entrypoint.sh"] 