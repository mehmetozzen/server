FROM node:20-alpine
WORKDIR /app
# Reproducible install: exact versions from the committed lockfile.
COPY docker/analytics-receiver/package.json docker/analytics-receiver/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY docker/analytics-receiver/receiver.js .
# This process parses unauthenticated player beacons — do not run it as root.
USER node
EXPOSE 9999
CMD ["node", "receiver.js"]
