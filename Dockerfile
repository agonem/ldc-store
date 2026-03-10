# ============================================
# Stage 1: Dependencies Installation
# ============================================
FROM node:20-slim AS deps

WORKDIR /app

# Enable corepack for pnpm
RUN corepack enable pnpm

# Copy package files for dependency installation
COPY package.json pnpm-lock.yaml ./

# Install dependencies with frozen lockfile
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

# ============================================
# Stage 1.5: Extract runtime deps for migration
# ============================================
FROM deps AS migrate-deps

# Resolve symlinks and copy postgres + drizzle-orm to a stable path
# (pnpm uses symlinked .pnpm store, so we need the real directories)
RUN mkdir -p /migrate-node-modules && \
    POSTGRES_PATH=$(readlink -f node_modules/postgres) && \
    DRIZZLE_PATH=$(readlink -f node_modules/drizzle-orm) && \
    cp -a "$POSTGRES_PATH" /migrate-node-modules/postgres && \
    cp -a "$DRIZZLE_PATH" /migrate-node-modules/drizzle-orm
# ============================================
# Stage 2: Build Next.js application
# ============================================
FROM node:20-slim AS builder

WORKDIR /app

# Enable corepack for pnpm
RUN corepack enable pnpm

# Copy dependencies from deps stage
COPY --from=deps /app/node_modules ./node_modules

# Copy application source
COPY . .

# Set production environment for build
ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Build Next.js application
RUN pnpm build

# ============================================
# Stage 3: Production Runner
# ============================================
FROM node:20-slim AS runner

WORKDIR /app

# Set production environment
ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME="0.0.0.0"
ENV NEXT_TELEMETRY_DISABLED=1

# Create non-root user for security
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

# Copy public assets
COPY --from=builder /app/public ./public

# Create .next directory with correct ownership
RUN mkdir .next && chown nextjs:nodejs .next

# Copy standalone output
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# Copy migration runtime dependencies (postgres, drizzle-orm)
COPY --from=migrate-deps --chown=nextjs:nodejs /migrate-node-modules/postgres ./node_modules/postgres
COPY --from=migrate-deps --chown=nextjs:nodejs /migrate-node-modules/drizzle-orm ./node_modules/drizzle-orm

# Copy runtime migration assets (for Task 5 entrypoint)
COPY --chown=nextjs:nodejs docker-entrypoint.sh ./
COPY --chown=nextjs:nodejs scripts/docker-migrate.mjs ./scripts/
COPY --chown=nextjs:nodejs lib/db/migrations ./lib/db/migrations

# Ensure entrypoint is executable
RUN chmod +x ./docker-entrypoint.sh

# Switch to non-root user
USER nextjs

# Expose port
EXPOSE 3000

# Use entrypoint for runtime migrations
ENTRYPOINT ["./docker-entrypoint.sh"]
