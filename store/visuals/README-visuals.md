# README visuals (proposal)

Proposed snippet for `README.md`, to replace the screenshot table under the intro paragraph. README.md itself is untouched. Paths assume `store/visuals/` is committed as is.

```markdown
<p align="center">
  <img src="store/visuals/readme-hero.png" width="100%" alt="Soma Flight on a Mac and two iPhones: My Flights on the globe, a Passport and a flight in the air">
</p>

| My Flights | Flight | Search | Airport | Passport | Friends |
|---|---|---|---|---|---|
| ![My Flights](store/visuals/iphone-63/01-home.png) | ![Flight](store/visuals/iphone-63/02-detail.png) | ![Search](store/visuals/iphone-63/03-search.png) | ![Airport](store/visuals/iphone-63/04-airport.png) | ![Passport](store/visuals/iphone-63/05-passport.png) | ![Friends](store/visuals/iphone-63/07-friends.png) |

Screenshots show demo data.
```

## Headlines used on the store slides

| Slide | Headline | Subline |
|---|---|---|
| Home | Every flight, live | Times, gates and delays update on their own. |
| Flight | Know before the board | Delays, gates and baggage belts as they move. |
| Search | Find any flight fast | Type a flight number, a route or an airport. |
| Airport | Every airport at a glance | Weather, FAA delays and runway closures. |
| Passport | Every trip you've taken | Your routes, distance and hours in the air. |
| Travel record | A travel record to share | Flights, airports and countries on one card. |
| Friends | See your friends' flights | Share a link. You choose what they see. |

## How to rebuild

Everything is in `sources/`: raw simulator and Mac captures (`raw/`), the AI sky backgrounds (`bg/`, atmosphere only, no UI and no airline marks), the generated HTML (`html/`) and the scripts (`scripts/`).

- `scripts/shot.sh <udid> <set> <name> <wait> [args]` relaunches the Debug app on fakes (`-useFakes YES` plus `-open`, `-tab`, `-fullPage`, `-detent`, `-fakeNoProvider`) and captures with `simctl io`.
- `scripts/macshot.sh <name> <wait> [args]` does the same for the Mac app window (`screencapture -o -l`).
- `scripts/compose.py iphone-69 iphone-63 ipad-13 mac hero` renders the slides with Playwright headless Chromium; `scripts/contact_sheet.py` builds `contact-sheet.png`.
- `scripts/gen_bg.py` made the three backgrounds (Azure gpt-image-2.5-flare, one call at a time).
