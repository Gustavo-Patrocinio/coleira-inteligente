# Collar backend image (Phase 4). Runs the TypeScript sources with tsx: no build step,
# so what runs in production is exactly what the tests ran.
FROM node:26.13-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund && npm cache clean --force
COPY tsconfig.json ./
COPY src ./src
COPY migrations ./migrations
ENV NODE_ENV=production
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1:3000/health || exit 1
CMD ["node_modules/.bin/tsx", "src/server.ts"]
