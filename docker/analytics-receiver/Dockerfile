# Pinned by digest as well as tag: tags move. Update deliberately with
#   docker buildx imagetools inspect <image>:<tag> | awk '/^Digest:/{print $2}'
FROM node:20-alpine@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293
WORKDIR /app
# Reproducible install: exact versions from the committed lockfile.
COPY docker/analytics-receiver/package.json docker/analytics-receiver/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY docker/analytics-receiver/receiver.js .
# This process parses unauthenticated player beacons — do not run it as root.
USER node
EXPOSE 9999
CMD ["node", "receiver.js"]
