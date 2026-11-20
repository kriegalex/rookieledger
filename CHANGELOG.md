# RookieLedger v0.7.0

- The Windows sync app has a window and an icon in the notification area. The window says whether the site
  answers, when your data was last synced and whether the addon's data was found. Closing it leaves the app running
  behind its icon: a click on the icon shows the window again, a right-click offers to show or hide it, or to quit.
  It opens when you start the app yourself, not when your session does.
- To show whether the site answers, the Windows app asks it every 10 minutes, without your token, when nothing
  else was sent in that time.
- Crafts made in a queue are counted right. The game gives a craft's skill point after the next craft has started,
  so the first craft of a queue was counted without its point and the last one's went to the craft before it. This
  was in the v0.6.2 beta; the addon is otherwise unchanged.
- The map, https://rookieledger.21crypto.ch/, has a page on privacy: what is recorded, sent and kept.
- Until version 1.0, RookieLedger is a beta: things can still change between versions.
