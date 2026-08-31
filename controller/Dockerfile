FROM node:20-bookworm-slim

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev

COPY src/ ./src/
COPY public/ ./public/

USER node
CMD ["node", "src/index.js"]
