Recorded side view sample for `RecordedSideViewProvider`. No provider is licensed, so nothing here is
provider artwork: the images are simple silhouettes generated for the tests (a fuselage, a wing and a
fin, red nose cone so a test can tell which way it points).

- `ZQA-B738.png` 1600 px wide, nose left. `ZQA-A320.png` 1300 px wide, drawn nose right (the sync mirrors it).
- `ZQB-B738.svg` vector, rendered 1600 px wide.
- `narrow-1000.png` 1000 px wide, not in the manifest; tests use it to check the 1200 px minimum.
- `manifest.json` lists the pairs (airline, type, file, format, nose, version = first 16 hex of the file's sha256).

ZQA and ZQB are not real airlines; tests insert them and remove them again. When a provider is
licensed, record a real sample from its API or delivery and replace these files.
