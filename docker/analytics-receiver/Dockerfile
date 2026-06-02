FROM node:20-alpine
WORKDIR /app
COPY docker/analytics-receiver/receiver.js .
EXPOSE 9999
CMD ["node", "receiver.js"]
