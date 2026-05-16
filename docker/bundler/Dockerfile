FROM node:20-alpine

WORKDIR /app

# Copy package.json and install deps (npm install resolves latest @playkit-js/kaltura-player-js)
COPY docker/bundler/package.json ./
RUN npm install --omit=dev && npm cache clean --force

COPY docker/bundler/server.js ./

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --retries=5 \
    CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["node", "server.js"]
