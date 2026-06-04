FROM node:20-alpine
WORKDIR /app
# Install deps first (cached unless package.json changes).
COPY docker/analytics-receiver/package.json .
RUN npm install --omit=dev --no-audit --no-fund
COPY docker/analytics-receiver/receiver.js .
EXPOSE 9999
CMD ["node", "receiver.js"]
