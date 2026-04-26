FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /sphere ./cmd/server

FROM alpine:3.19
RUN apk add --no-cache ca-certificates yt-dlp ffmpeg
COPY --from=builder /sphere /sphere
EXPOSE 8080
CMD ["/sphere"]
