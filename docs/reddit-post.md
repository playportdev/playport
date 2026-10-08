# Reddit post draft: Playport 0.4.0, GOG, Epic Games and your own games

Suggested subreddits: r/EmulationOniOS (where the 0.3 reports came from),
r/sideloaded, r/iosgaming, r/gog and r/EpicGamesPC for the store angle. Post as an
image post with the body as the first comment, or as a text post with the images
inline. The release link works only once the v0.4.0 draft is published.

Images: the two Library screenshots from the site, `site/screenshots/library-gog.webp`
(the GOG filter: Moonscars, Monster Train, Shogun Showdown, Duck Paradox) and
`library-epic.webp` (the Epic Games filter: Snakebird Complete, House of Golf 2,
Football Manager 2022, Death's Door). A short recording of an Epic game starting
signed in (Snakebird to its menu) would make a strong video post: none is made yet.

---

**Title:** Playport 0.4.0 is out: GOG + Epic games, online sign-in and your own PC games, running natively on iPhone 🎉

**Body:**

[images: Playport's Library filtered to GOG, then to Epic Games]

**Playport 0.4.0 is out, and it isn't only for Steam anymore.** 🎉

If you missed the earlier posts: Playport runs real **Windows PC games locally on a
stock, non-jailbroken iPhone**. No streaming and no PC in the loop: the game's own
`.exe` runs on the phone's CPU and GPU, with a controller in your hands.

**What's new**

🛒 **GOG and Epic Games.** Sign in under Settings › Accounts, right next to Steam.
Your whole library shows up in one place with each store's artwork: 171 games on
our test account across the three stores. Install, Update, Verify and Repair all
go through the same Downloads queue, straight onto the phone.

🔑 **Games sign in to their store, like on a PC.** This was the big one. A game now
gets what its store's launcher would give it:

- **Epic**: every Epic game starts signed in. Games on Epic Online Services sign in
  too: Snakebird Complete goes straight to its menu, signed in.
- **Steam**: games get the same tickets the Steam client hands them, so online
  logins work. Valheim logs in to its online service this way.
- **GOG**: Galaxy games sign in. Moonscars connects to GOG Galaxy.
- When a game opens a sign-in page (like Epic's one-time "Allow"), it pops up in a
  panel over the game. No app switching.

📁 **Bring your own games.** Have a DRM-free PC game? Press X in the Library and
pick its folder or a `.zip` from Files. It lands in your Library under Local.

🚪 **Death's Door runs.** It used to quit after about 14 seconds, out of address
space. Now it plays into the game.

⚡ **Also:** the 0.3.3 crash at launch on iOS 26.0.x is fixed, Steam demos show up,
online games connect more reliably, a smoother Vulkan path, a fix for a rare
freeze, and Wine 11.19 with Valve's latest Proton changes plus current FEX, DXMT,
DXVK, vkd3d-proton and Mesa.

**📋 The new way to tell us how your games run**

After 0.3 you sent us dozens of game reports in the comments, and that's what drove
this release. You're the compatibility testers here, so we made it much easier:

1. On the game's page, tap **Report a problem**. Playport packs all the logs into
   **one `.zip`**. No more digging through Files and compressing logs by hand.
2. Open the **report form on GitHub** (link below), pick how the game runs (**Works**,
   **Playable with issues** or **Broken**), and drag the zip in.
3. Your result goes on the **public compatibility list**.

**🎮 The compatibility list: [playport.dev/compatibility](https://playport.dev/compatibility/)**

Every game we've played on the phone and every game you've reported, with its
status, searchable and filterable. 32 titles on it so far, and it's built from your
reports. Before buying or downloading something big, check it. After you play
something, **add it**, working or not. A "Broken" report with a log is often the
fastest way to a fix: the iOS 26.0 launch crash fix and the one-zip reports came
straight from your reports.

**Known rough edges**

- Among Us crashes, Monster Train (GOG) is a black screen, and Jurassic World
  Evolution (Epic) doesn't start yet.
- Valheim: pick DXMT on its page (Vulkan shows black).
- Sign-in panels don't open for 32-bit games yet.
- Tested on one phone (iOS 27.0), so your reports from other iPhones matter even more.

**Get it**

- Release (IPA, full source, notices): https://github.com/playportdev/playport/releases/tag/v0.4.0
- Report a game: https://github.com/playportdev/playport/issues/new?template=problem.yml
- Compatibility list: https://playport.dev/compatibility/
- Install guide, including which sideloaders keep the increased memory limit and
  the SideStore fix: https://github.com/playportdev/playport#install

Sideload it with your own Apple ID and install over 0.3: your games, saves and
logins stay. Bring your own games from Steam, GOG, Epic or Files.

Playport is open source (GPL-3.0-or-later). Huge thanks to everyone behind Wine,
FEX, DXMT, DXVK, vkd3d-proton and Mesa/KosmicKrisp, and to everyone who
reported a game. Go break it and tell us how. 🙌
