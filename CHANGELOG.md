# RookieLedger v0.9.0

- Corpses you loot in a group now count, in a party under group loot, in the open world and in dungeons. A corpse
  counts for the member who takes its coin, so nothing is counted twice when several of you use the addon. The items
  the group rolls for count too, as they show in the corpse while the roll lasts.
- In a group, a corpse without coin does not count: most beasts carry none. Alone, they count as before.
- Under the other loot methods and in raids nothing counts yet. The notes on group loot go on, for those.
- The monster tooltip and `/ledger` add up the corpses looted alone and in a group.
- The sync app does not change.
- For who runs a site of their own: the record keeps the corpses looted in a group apart (`w`), and the read API
  adds them to the others and tells how many there are (`group_corpses`). A site older than v0.9.0 leaves them out,
  and takes them at the next upload once it is updated.
- Until version 1.0, RookieLedger is a beta: things can still change between versions.
