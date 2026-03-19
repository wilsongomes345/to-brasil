FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --omit=dev

COPY index.js .

# Ajuste de permissões para usuário e grupo node
RUN chown -R node:node /app

USER node

EXPOSE 3001

CMD ["node", "index.js"]
