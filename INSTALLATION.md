### Installation and updates

Download only Обновить.cmd into the folder where the game should be installed. Start it and accept the installation dialog. The dialog shows that folder's full path. Nothing is installed in the system, and administrator rights are unnecessary.

The repositories are private. A GitHub account with access to this pack is required. Git Credential Manager handles sign in and keeps credentials in the current user's credential store. No publisher accounts are copied.

The first installation includes mods, loader libraries, resources and Fenix's initial player preferences. Existing settings are always preserved. Settings in config, defaultconfigs, kubejs/config, options.txt and individual shader preferences are initial defaults: updates never overwrite them or restore settings the player deliberately deleted. New settings files for newly added mods are initialized once. Embedded resource packs, data packs and FancyMenu assets and layouts remain managed game content.

Worlds, accounts, server lists, logs, screenshots, caches and other player data are never copied from the publisher or touched by an update. Only explicitly permitted game files are deployed.

Subsequent runs check GitHub. An unchanged revision immediately opens Legacy Launcher without reinstalling files. A changed revision downloads new Git objects and deploys only changed managed files. Retired mods move out of mods into recoverable backups. Unknown personal files are preserved. Updated files are backed up and an interrupted deployment is restored on the next run.

The game is installed beside the button. Private updater files, Java and a clean Legacy Launcher are stored in .steampunk. The launcher can download missing vanilla game files and the appropriate game Java. Launcher sign in belongs to the player. After updating, the launcher opens with this game folder selected.

Author publishing uses Отправить.cmd in the author's original Git checkout. It refreshes the allowlisted player defaults, commits the changes with the author's description, uploads them and checks that GitHub reports the same revision. It never runs automatically from the player installer.

Configuration settings are preserved on player updates. Changes to gameplay configuration in a new release therefore affect new installations; existing players keep their own values.

Existing players must download and replace their old Обновить.cmd once before their next update. The old updater runs a forced checkout and cannot provide the new preservation guarantees during its own replacement. The new button can adopt an existing game folder without replacing its settings.