FROM node:20-alpine AS ui
WORKDIR /src
COPY ./ui/package-lock.json ./
COPY ./ui/package.json ./
COPY ./ui/babel.config.js ./
RUN npm set progress=false && npm config set depth 0 && npm install
COPY ./ui/public ./public
COPY ./ui/src ./src
RUN NODE_OPTIONS='--openssl-legacy-provider' npm run build

FROM --platform=$BUILDPLATFORM golang:1.21 AS build
WORKDIR /src
COPY . .
COPY --from=ui ./src/dist ./ui/dist
RUN go mod tidy && \
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o rover .

FROM alpine:3.18
COPY --from=build /src/rover /bin/rover
RUN chmod +x /bin/rover
EXPOSE 9000
WORKDIR /src
ENTRYPOINT ["/bin/rover"]
