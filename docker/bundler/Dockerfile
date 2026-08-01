FROM node:20-alpine

WORKDIR /app

# Reproducible install: exact versions from the committed lockfile. This bundle
# executes in every end user's browser — never float its version.
COPY docker/bundler/package.json docker/bundler/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

COPY docker/bundler/server.js ./
USER node

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --retries=5 \
    CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["node", "server.js"]
