# Manual regression checklist

Run on the M3 Pro before each beta. Automated tests cover the fake-runtime cases; these need
the real runtime, Steam and the game.

- [ ] Fresh setup from an empty data folder; Steam login and update; successful game launch
- [ ] Save, quit, relaunch, reload
- [ ] Game already running when Launch is pressed; Steam already running; launcher restarted mid-session
- [ ] Runtime removed; runtime on an unplugged external drive; low disk space
- [ ] Steam installer cancelled; prefix initialization interrupted (quit during init); game crash
- [ ] Unicode and space-containing paths for runtime, installer and save folder
- [ ] Diagnostics export: preview reviewed, no user name, tokens or environment dump
- [ ] Backup and restore; prefix delete cancelled; another Wine app (separate prefix) left untouched by Shut Down Prefix
- [ ] Launch from Finder (not Terminal); install from the zip on a fresh macOS user account
