# RookieLedger v0.4.0

- New: quest items. A monster only gives a quest item to who has the quest, so the addon now counts it apart: of
  the corpses you looted while your quest still wanted the item, how many held it. It finds the quest in your quest
  log the first time the item shows; that first corpse is not counted.
- The window no longer says a corpse held nothing when it held a quest item: the item is named, marked as a quest
  item.
- For who runs a guild site: update `server/` to keep the quest items of the uploads. An older site still accepts
  the uploads and leaves them out.
