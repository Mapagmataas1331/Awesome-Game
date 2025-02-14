FROM golang:1.20-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o ag-ws .

FROM alpine:latest
WORKDIR /root/
COPY --from=builder /app/ag-ws .
EXPOSE 8080
CMD ["./ag-ws"]
