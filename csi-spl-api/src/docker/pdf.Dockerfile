# The renderer service of spec 183 (7.1.6): cmd/spool-pdf and headless
# Chromium, nothing else. POST /render turns the hub's self-contained topic
# HTML into a PDF; only the hub's service account may call it (Cloud Run IAM,
# terraform step 031-cloud-run-pdf). It scales to zero and holds nothing
# while idle (spec 183 1.2 R1), so its size costs a cold start, never the hub.
#
# Build context: the Go module, so the builder gets nothing else:
#   docker build -f csi-spl-api/src/docker/pdf.Dockerfile csi-spl-api/src/go/spool-hub-api
# Base images come through mirror.gcr.io, as hub.Dockerfile's do.
FROM mirror.gcr.io/library/golang:1.26-alpine AS build
ENV CGO_ENABLED=0 GOTOOLCHAIN=auto
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN go build -trimpath -ldflags "-s -w" -o /out/spool-pdf ./cmd/spool-pdf

FROM mirror.gcr.io/library/alpine:3.22
# chromium + font-dejavu: ~795 MiB (spec 183 1.1); the fonts give the PDF
# Latin, Cyrillic and Greek. The user is non-root; Chrome runs with
# --no-sandbox, as a Cloud Run container has no user namespaces for its own.
RUN apk add --no-cache chromium font-dejavu ca-certificates \
 && addgroup -S -g 10001 spool && adduser -S -D -H -u 10001 -G spool spool
COPY --from=build /out/spool-pdf /usr/local/bin/spool-pdf
ENV SPOOL_PDF_CHROME=/usr/bin/chromium-browser \
    PORT=8080
USER spool
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/spool-pdf"]
