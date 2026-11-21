# The site as one image: the upload service, the read API and the admin command, Python standard library only.
# Built and published by the release workflow as ghcr.io/kriegalex/rookieledger-server:<tag>.
#
#   docker build --build-arg VERSION=dev -t rookieledger-server server
#   docker run -v ledger:/app/data -p 8787:8787 rookieledger-server server/ledger_ingest.py --registration open
#   docker run -v ledger:/app/data -p 8788:8788 rookieledger-server                      # the read API
#   docker exec <container> python3 -I server/ledger_admin.py digest
#
# The base image is named by digest, so that the same tag of this image is always the same bytes; Dependabot
# proposes the newer one.
FROM python:3.15-slim@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928

ARG VERSION=dev
LABEL org.opencontainers.image.title="RookieLedger server" \
      org.opencontainers.image.description="Upload service and read API of RookieLedger" \
      org.opencontainers.image.source="https://github.com/kriegalex/rookieledger" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}"

# The services say this version on /healthz.
ENV LEDGER_VERSION=${VERSION}

# Same layout as the repository: the database is /app/data/ledger.sqlite, the one path that must be writable.
WORKDIR /app
COPY ledger_admin.py ledger_api.py ledger_common.py ledger_ingest.py server/

# Not root, and no name needed: the services run with a read-only root filesystem.
USER 1000:1000
# 9102 answers only when the read API is started with --metrics-port 9102 (or LEDGER_METRICS_PORT).
EXPOSE 8787 8788 9102
ENTRYPOINT ["python3", "-I", "-B"]
CMD ["server/ledger_api.py"]
