# Forever client behaviour, verified in game

What the World of Warcraft: Forever client tells an addon about kills, corpses and loot. Every statement in the
numbered sections was observed in the running game and is given with the number of cases behind it. What was only
read elsewhere, or reasoned from the observations, is kept apart in [Not verified](#not-verified).

Use this page before changing how the addon decides what a loot window is, or what it counts. When the client
changes, repeat the observation and correct the page.

## Where the observations come from

| | |
|---|---|
| Client | Forever, interface 16001, build 70959, French (frFR) |
| Character | Undead rogue with Skinning, from level 4 up, alone (not in a group) |
| Place | Tirisfal Glades, open world, with many other players around |
| Size | 636 monster deaths nearby, 63 of them the character's own kills, 95 loot windows, 27 Skinning casts, 9 Pick Pocket casts |
| Quests | 13 minutes with 12 quests in the log: 46 loot windows, 9 of them holding a quest item (3 different items) |
| Creatures killed | 12 kinds: 1501, 1504, 1505, 1506, 1507, 1508, 1512, 1547, 1548, 1553, 1667, 1919 |

Sections 1 to 5 come from [`tools/Probe.lua`](../tools/Probe.lua) and section 8 from
[`tools/QuestProbe.lua`](../tools/QuestProbe.lua): files added to the installed addon for the time of the
observation, which register the events below, call the functions below at fixed moments and write one line per
answer to a saved variable. They record nothing in the ledger. To repeat an observation, follow the steps at the top
of the file. Sections 6 and 7 come from playing with the addon and reading its saved files afterwards. Section 10 comes
from a line typed in chat that prints the three events with the skill, read off a screenshot.

Nothing here was observed in a dungeon, in a group, or outside that starting zone.

## 1. Kills and deaths

An addon can hear deaths without the combat log.

| Event | Carries | Seen |
|---|---|---|
| `PARTY_KILL` | the killer's GUID, the monster's GUID | Registers. Fired for all 63 own kills, naming the character as the killer. |
| `UNIT_DIED` | the monster's GUID | Registers. Fired for all 636 deaths nearby, whoever killed the monster. |

- For an own kill both events fire in the same instant, `PARTY_KILL` first.
- `UNIT_DIED` alone says nothing about whose kill it was: 573 of the 636 deaths were not the character's kills.
- `PARTY_KILL` fired once naming another player as the killer. That corpse was nevertheless the character's to
  loot, and was looted. So the event is not limited to the character's own killing blows, and "killed by someone
  else" does not mean "not mine to loot".
- Every GUID arrived as a plain string of the form `Creature-0-<server>-0-<zone>-<creature id>-<spawn>`. No hidden
  ("secret") value and no error was met.

## 2. Whether a corpse holds loot

`CanLootUnit(guid)` answers for a corpse without opening it. It returns two booleans; the first says whether the
corpse holds something for this character.

The first value, for the 63 own kills:

| Moment | Answer |
|---|---|
| At the death event | `false` for all 63: the loot does not exist yet |
| 0.5 s later | `true` for all 63 |
| Until the corpse is looted | stays `true`: a corpse left alone for 8 s answered `true` at 2 s and at 5 s |
| 0.5 s after its loot window closed | `false` in 67 of 68 cases; the one `true` is unexplained (a corpse looted in part would fit) |
| Once a Skinning window has opened on it | `true` again (27 of 27), even after that window closed |

For monsters killed by other players the first value was `false` in 2231 of 2234 answers. The function returned
nothing at all 50 times, each time for a monster that had died some seconds earlier and far away.

Consequences:

- Ask at least half a second after the death, never at the death event.
- Ask before skinning. After a Skinning cast the answer no longer tells whether the monster dropped anything.

## 3. Whose corpse it is

`UnitIsTapDenied(unit)` needs the corpse under the target or the mouse; it does not take a GUID.

| Corpse | Answer |
|---|---|
| Own kill | `false` in all 185 readings |
| Not an own kill | `true` in 60 of 66 readings; the six `false` include the corpse of section 1 that was the character's to loot |

A corpse of another player's kill can be skinned once its owner has looted it. Skinning it opens a loot window that
names that creature, exactly as for an own corpse. This happened four times in the first six minutes of observation.

## 4. Loot windows

- `LOOT_READY` is announced twice for one window: 95 of 95 windows, 0.2 to 0.3 s apart.
- `LOOT_READY` can also come before the window has any content: 3 announcements showed no slot at all.
- `GetLootSourceInfo(slot)` named a creature's GUID in every one of the 95 windows.
- A window opened by Skinning or Pick Pocket names the creature in the same way as a corpse window. Only the cast
  that came before it tells them apart.
- `UNIT_SPELLCAST_SUCCEEDED` was reported before the window in 27 of 27 Skinning casts and 9 of 9 Pick Pocket
  casts. The Pick Pocket window followed 0.0 to 1.7 s after the cast.

## 5. How often a kill holds nothing

All 63 own kills held loot: 60 corpses were opened, 3 answered `true` and were left unopened. None was empty.

A corpse that holds nothing opens no loot window, so the addon cannot count it. With no empty corpse in 63 kills,
the share of empty corpses is below about 5 % for these creatures, and "per corpse looted" is close to "per kill".
About 21 of the 63 were beasts; for beasts alone the bound is nearer 14 %.

A corpse that was skinned but never looted is not evidence of an empty corpse: in a busy zone it is usually another
player's kill (see section 3).

## 6. Pick Pocket and Skinning

- A Pick Pocket that gives coin opens a loot window. The coin is not part of what the monster drops: a monster
  whose pocket gave 1 copper held 2 copper as a corpse afterwards.
- A second Pick Pocket on the same monster is refused with a red error message. No loot window opens and the cast
  is reported as failed.
- The localized spell names come back at once from `C_Spell.GetSpellName`: "Dépeçage" (8613), "Vol à la tire"
  (921), "Minage" (2575). `GetSpellInfo` returns nothing on this client.

## 7. Saved files and the interface

- The account-wide and the per-character saved files are both written at `/reload` and at logout. The
  per-character one is `WTF/Account/<account>/<realm>/<character>/SavedVariables/RookieLedger.lua`.
- A corpse looted in part can be opened again after a `/reload`; its GUID is unchanged.
- A new file and a changed `.toc` were taken up by a full restart of the game. Whether a `/reload` is enough was
  not tried.
- `C_AddOns.GetAddOnMetadata(addon, "Version")` returns the `## Version:` field of the `.toc`: a released copy
  announced its own version at login.
- `## IconTexture:` accepts a 64 x 64, 32-bit, uncompressed TGA inside the addon's folder.
- Working as in other clients: `Settings.RegisterCanvasLayoutCategory` with `Settings.RegisterAddOnCategory`, the
  `BackdropTemplate`, `UIPanelCloseButton`, `UIPanelButtonTemplate` and `UICheckButtonTemplate` templates, a
  `ScrollingMessageFrame` with hyperlinks and top insert mode, `SetItemRef` for a clicked item link, and a minimap
  button through LibDataBroker and LibDBIcon.

## 8. Quest items and the quest log

Which functions exist:

| Present | Absent |
|---|---|
| `C_QuestLog.GetNumQuestLogEntries`, `GetInfo`, `GetQuestObjectives`, `IsOnQuest`, `IsComplete`, `GetLogIndexForQuestID`, `GetQuestIDForLogIndex`, `ReadyForTurnIn`, `UnitIsRelatedToActiveQuest` | the globals `GetNumQuestLogEntries`, `GetQuestLogTitle`, `GetItemInfoInstant`, `IsQuestItem` |
| the globals `GetNumQuestLeaderBoards`, `GetQuestLogLeaderBoard`, `GetQuestLogSpecialItemInfo`, and `C_Item.GetItemInfoInstant` | |

What they return:

- `C_QuestLog.GetInfo(index)` gives a table with `questID`, `title` and `isHeader`; the log held 12 quests.
- `C_QuestLog.GetQuestObjectives(questID)` gives one table per objective with `text`, `type` (`item`, `monster` or
  `object` were seen), `finished`, `numFulfilled` and `numRequired`.
- The text of an item objective is the item's name, a colon and the count: "Sang de sombredogue : 1/5". In French
  the space before the colon is a no-break space (bytes `C2 A0`), not a plain one. The objective carries no item
  id: the name is the only link to the item.
- For about two seconds after login the item's name is missing from that text ("  : 1/5"), for all 10 item
  objectives. A `QUEST_LOG_UPDATE` follows and the names are there.

Quest items in a loot window:

- `GetLootSlotInfo(slot)` returns `true` as its seventh value for a quest item: 9 of 9 quest slots, and `false`
  for all 44 other slots. It returns no quest id (eighth and ninth values `nil`).
- `C_Item.GetItemInfoInstant` gives class 12 (Quest) for each of the three items.
- Exactly one objective of the log named the item, in 9 of 9 windows.
- A quest item also comes from world objects (a `GameObject` source), not only from corpses: 5 of the 9 windows.
- One quest item dropped from two kinds of monster (creatures 1547 and 1548).

After a quest item is looted, within 0.6 to 0.7 s of its window:

- `QUEST_WATCH_UPDATE` with the quest's id, `UNIT_QUEST_LOG_CHANGED` for the player, and `UI_INFO_MESSAGE` with
  type 317 and the text "Sang de sombredogue : 2/5". The three come in no fixed order.
- The objective's `numFulfilled` has gone up by then, and `finished` turns `true` on the last one, with a further
  `UI_INFO_MESSAGE` of type 314.

## 9. Where a monster is

The client tells an addon where the player stands, not where a monster does. Asked once, with a monster as the
target, in the open world:

| Asked | Answer |
|---|---|
| `UnitPosition("target")` | `nil, nil, nil, 0` |
| `C_Map.GetPlayerMapPosition(map, "target")` | `nil` |

So the place the addon notes for a looted corpse is the player's own, taken when the loot window opens: within
looting reach of where the monster died. Where it stood before it was pulled cannot be read.

## 10. Crafts in a queue and the skill point

Five crafts of one recipe, queued in the profession window (Leatherworking from skill 1, "Cuir léger", every craft
giving a point). A line of chat was printed at each event, with the skill `GetProfessionInfo` gave at that moment:

| Event | Skill read |
|---|---|
| `UNIT_SPELLCAST_START` of craft 1 | 1 |
| `UNIT_SPELLCAST_SUCCEEDED` of craft 1 | 1 |
| `UNIT_SPELLCAST_START` of craft 2 | 1 |
| `CHAT_MSG_SKILL` (the point of craft 1) | 2 |
| `UNIT_SPELLCAST_SUCCEEDED` of craft 2 | 2 |
| `UNIT_SPELLCAST_START` of craft 3 | 2 |
| `CHAT_MSG_SKILL` (the point of craft 2) | 3 |

and so on to the fifth craft, whose point came after its `UNIT_SPELLCAST_SUCCEEDED` with no cast after it.

- The point of a craft comes after the craft's `UNIT_SPELLCAST_SUCCEEDED`, and in a queue after the
  `UNIT_SPELLCAST_START` of the next craft: 4 of 4 crafts that had a craft after them.
- It is in before that next craft's `UNIT_SPELLCAST_SUCCEEDED`: 4 of 4.
- So the skill read when a queued craft starts is the skill before the point of the craft before it. The addon
  reads it again once that point is in (`ResolveCraft` in `Scan.lua`).

## Not verified

Read elsewhere, not tried:

- The combat log (`COMBAT_LOG_EVENT_*`) is closed to addons, and registering for it gets the addon blocked. Two
  other addons say so in their code and on their pages. RookieLedger has never registered for it.
- Inside dungeons the client hides which monster died (the GUIDs of `PARTY_KILL` and `UNIT_DIED` arrive as secret
  values). From another addon's code.

Reasoned from the observations, not seen directly:

- The second value of `CanLootUnit` follows how close the corpse is, not whose it is. It was `true` for every own
  kill at the moment of death and for other players' corpses under the mouse, and `false` for deaths far away.
- An empty own corpse would answer `false` to `CanLootUnit` from half a second after the death onwards. No empty
  corpse was met, so this answer was never seen.

Never met:

- How long after a craft its point comes when no craft follows: the addon waits 1.2 s. The one case seen came
  before the next line of chat, and was not timed.
- A queue of a recipe that does not give a point at every craft, and a craft shorter than that wait.
- Whether a monster still gives a quest item once the objective is reached. Both observations ended at the
  objective's last item.
- An item that two quests of the log ask for at once.

- A first, successful Pick Pocket on a monster with nothing in its pocket: whether a loot window opens.
- Loot in a group, where a window shows one member's share.
- Higher-level monsters, elites and bosses: whether they can hold nothing.
