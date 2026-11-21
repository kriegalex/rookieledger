# RookieLedger v0.7.2

- Nothing changes in the addon or in the sync app: this version is about the site.
- For who runs a site of their own: the read API can give its numbers to Prometheus on a port of its own
  (`--metrics-port`), among them how many tokens are held and wait for `approve`. The health probes no longer fill
  the log.
- Until version 1.0, RookieLedger is a beta: things can still change between versions.
