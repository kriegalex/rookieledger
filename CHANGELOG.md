# RookieLedger v0.6.2

- Crafts made in a queue are counted right. The game gives a craft's skill point after the next craft has started,
  so the first craft of a queue was counted without its point and the last one's went to the craft before it.
- The package holds the addon alone: v0.6.1 also carried the files of the map page. Its four libraries are taken at
  fixed versions.
- The map, https://rookieledger.21crypto.ch/, loads every place in one request. Far out, the places of one kind
  that lie close together are drawn as one mark; a click on it comes closer, until they are apart.
- For who runs a site: the read API has `/v1/places`, every place of every map in one document, and the upload
  service refuses a saved file of more than 250,000 values, six times what a year of one account's play holds.
- Nothing else changes in what is recorded or sent.
