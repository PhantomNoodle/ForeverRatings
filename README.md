# Forever Ratings

Rate other players, and see what the community thinks of a player before you invite them.

## Rating
- You can rate **anyone** with **1 to 5 stars** (1 is very low, 5 is very high) and an optional comment. Your character must be level 55 or higher.
- **One vote per player.** Each person's rating of a player counts once. Rate them again and the new score replaces the old one, which stops counting.
- **Changes once a week.** After you rate someone, you have to wait 7 days to change it. The rating window shows "your vote, can change in N days" until then.
  - Every client enforces this, so a modified addon can't skip the wait. A change that arrives too soon is thrown away.
  - **Withdraw my rating** in the viewer works any time, but rating again afterwards still waits a week.
- After a dungeon or raid run (a boss killed, a finder dungeon finished, or a keystone completed), a **"How was <dungeon>?"** window lists your groupmates.

Use `/rate` for your current or last run, `/rate <name>` for anyone, or right-click a player and pick **Rate player...**.

## Seeing ratings
- **Tooltips** on players, and on Group Finder leaders and applicants, show `Rating: 4.2 (220)`, the score and the number of votes that count, and the latest comment. Players with no counted votes show `Rating: unrated`. Your own tooltip shows your own score.
- **Group Finder lists**: each search result shows the group leader's rating (`Leader 4.2 (12)` or `Leader unrated`). In your own listing, every applicant, including each member of a group application, has their rating next to their name. Search results only reveal the leader's name, so the other members of a listed group can't be shown until they join you.
- The score is the average of the ratings that count, so it can be a decimal (3.2) even though every rating is whole stars.
- **`/ratings`** opens the viewer, starting on your own score. It lists rated players with their score. Pick one to see every rating, with who wrote it, when, which dungeon, the comment, and why a rating doesn't count if it doesn't.

## How ratings are shared, and why they're hard to fake
Addons can't use the internet, so ratings travel between players through the game itself:
- Everyone with the addon joins a hidden chat channel. A new rating is sent there and stored by everyone online.
- When you log in, you ask the channel for anything you missed, and a couple of online players send it. You also re-send the ratings you wrote, so people who were offline get them.

A rating only counts toward a score if all of these are true:
- **It came straight from its author.** The game server tells the addon who sent each message, and that can't be faked. Ratings passed along by someone else show as *unverified* until the author is online and sends them in person. A relayed copy can never replace a verified rating.
- **The author is level 55 or higher.** Each message carries the sender's level, and your client checks it against the real level whenever the game shows it (group, guild, target, mouseover). The real level always wins.
- **It isn't about the author themselves.** Every client throws self-ratings away.
- **It's the author's only vote for that player.** A changed vote replaces the old one, and only after the 7-day wait. This is checked by every *receiving* client, not by the sender, so editing the addon doesn't get around it.
  - Each client starts the 7 days from when it received the old vote, not just from the date the sender wrote on it. Backdating a first vote doesn't help.
  - Ratings dated in the future are rejected.
  - A changed vote can reach a player who never saw your earlier one before the week is up. To them it's simply your one vote, so it still counts only once.

Also, players who flood the channel are ignored for a while, and unverified ratings that are never confirmed expire after 30 days.

What this can't stop:
- **Several game accounts:** someone with several accounts can rate their own main from other characters, because each account really is a different sender. Ratings from many different people are the thing to trust.

## Limits
- Ratings reach you only from players who are online at the same time as you, or through catch-up when you log in. A brand new install takes a while to fill up.
- While a boss fight, keystone or PvP match is in progress, the game blocks addon messages. Ratings wait in a queue and go out afterwards.
- Comments are public to everyone with the addon and limited to 120 bytes.

## Commands
| Command | Does |
|---|---|
| `/rate` | Rate your current or last run |
| `/rate <name>` | Rate any player |
| `/ratings [name]` | Open the viewer |
| `/ratings prompt` | Turn the after-run window on or off |
| `/ratings sync` | Ask the network for missed ratings |
| `/ratings status` | Storage and network info |

## Install
1. Open the [Releases page](https://github.com/PhantomNoodle/ForeverRatings/releases/latest) and download `ForeverRatings-<version>.zip` (under **Assets**).
2. Close the game, or at least log out to the character screen.
3. Extract the zip into your Forever addons folder, usually:
   ```
   C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns
   ```
   You should end up with `AddOns\ForeverRatings\ForeverRatings.toc`. If you get `AddOns\ForeverRatings\ForeverRatings\...` instead, move the inner folder up one level.
4. Start the game. On the character screen, open **AddOns** and make sure **Forever Ratings** is ticked. If it says "out of date", tick **Load out of date AddOns**.

To update, download the new zip and extract it over the old folder (replace the files when asked). Your ratings are kept, they live in `WTF\`, not in the addon folder.

To uninstall, delete the `AddOns\ForeverRatings` folder.

### Releases
A new release with the packaged zip is built automatically when the `## Version:` line in `ForeverRatings.toc` changes on `main`. It can also be run by hand from the **Actions** tab (**Release**, then **Run workflow**). If a release for that version already exists, nothing happens.
