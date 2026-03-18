FROM node:20-alpine

WORKDIR /app

# node:alpine já tem o usuário "node" (uid=1000) — usamos ele
COPY package*.json ./
RUN npm install --omit=dev

COPY index.js .

# Garante permissões corretas
RUN chown -R node:node /app

USER node

EXPOSE 3001

CMD ["node", "index.js"]
