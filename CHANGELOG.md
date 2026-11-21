# RookieLedger v0.7.1

- Nothing changes in the addon or in the sync app: this version is about the site.
- For who runs a site of their own: each release now publishes the server as a container image,
  `ghcr.io/kriegalex/rookieledger-server`. The upload service and the read API both say which version they run on
  `/healthz`, and both stop at once when asked to.
- Until version 1.0, RookieLedger is a beta: things can still change between versions.
