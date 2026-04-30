FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /sphere ./cmd/server

FROM alpine:3.19
# yt-dlp from Alpine apk lags behind YouTube's frequent cipher changes; install
# the upstream release via pip so cold starts always boot with a working build.
# python3 is needed at runtime (yt-dlp is a Python script).
RUN apk add --no-cache ca-certificates ffmpeg python3 py3-pip \
    && pip install --no-cache-dir --break-system-packages -U "yt-dlp>=2025.1.15" \
    && yt-dlp --version
COPY --from=builder /sphere /sphere
EXPOSE 8080
CMD ["/sphere"]
