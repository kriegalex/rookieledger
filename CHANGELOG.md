# RookieLedger v0.1.1

Addon

- Guild sync sends only the lines that changed instead of the whole record after every craft.
- Guild sync waits during encounters and battlegrounds instead of dropping what it had to send.
- A made-up record sent under your id is replaced by your real one; impossible change counters are ignored.
- Records received in one guild are no longer passed on in another.
- A corpse looted while a disenchant is being cast is no longer taken for its result.
- A future change of the saved format keeps your token and your data.
- This version does not exchange records with v0.1.0: update every member.

Companion app

- Windows: the app installs itself to a fixed folder, so moving or deleting the download no longer stops the
  uploads, and double-clicking a newer download updates it.
- Windows: a game folder with accents in its path is found; two Windows users on one PC each get their own copy.
- Folders with brackets in their name are found.
- `--url` is remembered.
- The log no longer holds the whole token, and `--status` says why the site refused a file.
- Built with a supported Go version.

Site

- A token can only upload the record id of its first upload.
- A very large record is cut to size instead of being refused.
