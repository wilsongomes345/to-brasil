FROM node:25-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --omit=dev

COPY index.js .

RUN chown -R node:node /app

USER node

EXPOSE 3001

CMD ["node", "index.js"]
