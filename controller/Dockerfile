# syntax=docker/dockerfile:1
FROM golang:1.25.7-alpine AS build
ARG VERSION=dev
ARG COMMIT_SHA=unknown
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -trimpath \
    -ldflags="-s -w -X main.version=${VERSION} -X main.commitSHA=${COMMIT_SHA}" \
    -o /out/runner-controller .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/runner-controller /runner-controller
ENTRYPOINT ["/runner-controller"]
