# RookieLedger v0.8.0

- In a group, the addon now notes what the game shows of loot there: whose corpse it is, what its window holds,
  the rolls and who received what. Nothing of it counts yet, in your record or on the site: these notes are what
  a later version will be built from, so that group play can add to the shared data too. They hold no name and no
  chat text.
- The sync app does not change: it already sends the file these notes are in.
- For who runs a site of their own: the notes are kept apart from the records, for 90 days, and
  `ledger_admin.py group-log` prints them.
- Until version 1.0, RookieLedger is a beta: things can still change between versions.
