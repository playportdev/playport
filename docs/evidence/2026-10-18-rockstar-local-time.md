# Local time on the phone: KUSER_SHARED_DATA.TimeZoneBias (PLA-401)

**Linear:** https://linear.app/playportdev/issue/PLA-401. Change: `patches/madeira-unix` 0159,
WineHost `timezone_bias.c`, `app/tests/timezone_bias_test.c`.

## The defect

**What the phone showed.** Every Rockstar `launcher.log` pulled from the phone is stamped in UTC.
- Runs `20261018T114545`, `120626` and `211446` were started at 11:45, 12:06 and 21:14 local time (CEST). Their logs start at 09:46, 10:06 and 19:15.
- The same logs report "Time Zone: Central Europe Daylight Time (Currently in Daylight Savings Time)".
- Under desktop Wine the launcher logs local time.

**Where it comes from:**
- ntdll's `RtlSystemTimeToLocalTime` subtracts `SystemTimeOfDayInformation.TimeZoneBias`. In the unix ntdll that value is `KUSER_SHARED_DATA.TimeZoneBias`.
- Upstream wineserver publishes it in `set_user_shared_data_time` (`server/fd.c`).
- Madeira's iOS replacement (`build/wineserver/fd_ios.c`) never did. Its comment says computing it "needs gmtime/localtime/mktime, which take libc's timezone lock and share a static buffer in a process where wineserver and every guest thread share libc". So it kept its initial 0.
- `GetTimeZoneInformation` reads the real zone. On the phone, `GetLocalTime` therefore returned UTC while the zone said UTC+2.

## The fix

**Where the bias is computed.** The host computes it once, the way upstream does including the
daylight-saving adjustment (`pp_timezone_bias`), at a point where nothing else is running:
- It runs in `wine_host.c`, before `pthread_create` of the wineserver thread.
- The guest thread is only started later, by `wine_host_session_start` → `start_guest`, which needs the server already started.
- At that point no Wine thread exists that could be suspended while holding libc's time zone lock.
- The reentrant `gmtime_r`/`localtime_r` keep it off the shared static `struct tm`.

**How the server publishes it:**
- The server takes the value through `wineserver_set_timezone_bias` (madeira-unix 0159).
- It publishes it with `ios_usd_publish_timezone_bias` once, when `create_user_data_mapping` creates the shared page. That happens in both of its iOS branches.
- The periodic path still does not touch it. A daylight-saving change during one app session goes unseen until the next start, which comes after each game.

**Test.** `app/tests/timezone_bias_test.c` (`pp test`, "time zone bias") covers UTC, Europe/Berlin
(CET and CEST), Asia/Kolkata (+5:30), America/New_York (a positive bias) and Australia/Adelaide
(+9:30 and +10:30).
- For each one, the bias is the negated UTC offset in 100 ns units.
- UTC minus the bias equals libc's local time.
- Negative control: the old constant 0 is right only in UTC.
