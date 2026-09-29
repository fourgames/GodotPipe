# GodotPipe

[![GodotPipe video: export a Godot project and publish it to itch.io and Steam](https://img.youtube.com/vi/ksOVssbsI_E/maxresdefault.jpg)](https://youtu.be/ksOVssbsI_E)

> **Get a stable build on [itch.io](https://fourgamesab.itch.io/godotpipe).** The downloads there are tested releases, ready to run, without the repo's extra files. They're paid, which supports development.
> The source code here is free and open source, but you'll need to build it yourself with Godot, and it may be experimental.

Desktop app that exports a Godot project and uploads the build to itch.io with butler, to Steam with SteamCMD, or to both in one go.

## Getting started

The **Setup** page in the sidebar holds the tools and accounts shared by every app, one pair per store:

- **itch.io:** point GodotPipe at butler, itch.io's upload tool (Find, folder or **Download butler**), then paste an API key from itch.io → Settings → API keys and press **Sign in**.
- **Steam:** point GodotPipe at a SteamCMD binary (Find, folder or Download button), then enter your Steam account and press **Sign in**.

You only need the store you publish to; a Steam developer account is not required for itch.io. Until one store is set up, the **+** button next to **Apps** opens the Setup page instead of adding an app. The verified sign-ins are remembered in `user://settings.cfg`; changing the Steam username or the itch.io key asks for a new sign-in.

## Publishing to itch.io, Steam or both

The **Steam** and **itch.io** sections of each app have a checkbox in their header that switches publishing to that store on or off; a new app starts with every store that is set up switched on. **Build & Publish** exports each row once, then uploads to Steam first and itch.io second, all in the same console. Before exporting it asks each store whether the upload can work (Steam: depot IDs and branch; itch.io: the API key and the game), and a store that fails that check, or its upload, does not stop the other one. The banner shows one line per store.

For itch.io, set the app's **Game** as `user/game` (for `https://you.itch.io/my-game` that is `you/my-game`; pasting the page address works too) or pick it with the list button next to the field; the game's cover then shows beside the card, and the Page row says whether it is still a draft. The game has to exist on itch.io first; it can stay a draft. Each build row is pushed to its own **channel**, filled in from the row's platform: `windows`, `mac`, `linux` or `html5`. itch.io tags channels whose name contains windows, mac or linux with that platform; an empty channel skips the row on itch.io. The version itch.io shows comes from the project's `application/config/version`; for an app that only publishes to itch.io, the text field next to the publish button sets it instead. For Steam, that field is the build description.

**Web builds** (a Web export preset) go to itch.io only: they are exported as `index.html` with its files next to it. After the first push, open the game's edit page on itch.io, set Kind of project to HTML and tick "This file will be played in the browser" on the html5 upload; butler cannot do that for you. A preset with thread support needs "SharedArrayBuffer support" switched on there as well.

The itch.io API key is kept like the Steam password (see below): in the system's credential store with **Remember** on, otherwise only in memory. It reaches butler through the `BUTLER_API_KEY` environment variable of that one process, never on its command line, and the console and the copied report mask it. butler is downloaded from itch.io's official `broth.itch.zone` for macOS (universal), Windows (x64, also used on Windows on ARM) and Linux (x64 and ARM64). A butler installed by the itch desktop app is found too and left for the itch app to update.

Shortcuts (Ctrl on Windows and Linux, Cmd on macOS): **Cmd+Enter** builds and publishes the app on screen (plain Enter in the build description doesn't), **Cmd+N** adds an app and **Cmd+J** shows or hides the console. The window size, layout and last app are restored on the next launch.

## When something fails

Every failure is explained in the console: the checks before a build name the field to fix, and when SteamCMD or Godot fails with a known problem (wrong password, rate limit, missing permissions, missing export templates, …) a **How to fix** line and the banner say what to do. If that does not help, press the copy button in the console header: it copies the whole console together with a setup report (versions, paths, setup state and app settings), with the password, shared secret, itch.io API key, account names and home folder removed, ready to paste to an AI or on Discord. Closing the window while something runs stops it; during Build & Publish it asks first, and so does the stop button. A finished upload, and a failure the app doesn't recognise, also show as a banner, so you see the outcome with the console hidden.

## Build rows and the Executable column

Each row of the **Builds** table pairs an export preset with an executable name, plus a Steam depot ID when Steam is on and an itch.io channel when itch.io is on. Every row is exported into a folder of its own and uploaded from there. Type only the base name (it defaults to the project name); the extension is fixed by the preset's platform: `.exe` for Windows, `.x86_64` for Linux and `.app` for macOS. Godot names the executable and its `.pck` after it, and SteamCMD uploads the whole depot folder. Steam itself does not care about the name, but the launch option you set in Steamworks → Installation → General must point at the same file, e.g. `MyGame.exe` or `MyGame.app`. macOS presets are exported as a zip that the app unpacks before upload, so the `.app` bundle is what ships.

## Publishing non-Godot content (soundtracks, etc.)

The **+** button next to **Apps** accepts any folder. If it has no `project.godot` it is added as a content folder: the Godot section disappears, and each build row pairs a folder with a depot ID (and an itch.io channel) instead of an export preset (the first row defaults to the app folder itself; use the folder button to point a row elsewhere). Build & Publish skips the Godot export and uploads every file in each folder as-is to its depot and channel. **Fetch** in the Builds header works the same way. Use this for soundtrack apps, DLC, or builds produced by another engine or tool.

## Fetching depots from Steam

With Steam on, press **Fetch** in the Builds header to fill the table from the App ID. The app runs SteamCMD with your login and `app_info_print`, then adds a row for every content depot that is not already listed, picking an export preset whose platform matches the depot's OS. Only depots that are published in the app's configuration on the Steamworks partner site show up, so create the depots and publish the config there first.

## Branches and setting builds live

**Set live on branch** is SteamPipe's `SetLive` option: after a successful upload SteamCMD sets the build live on that branch. Leave the field empty to upload without setting anything live. SteamCMD cannot create branches, so a beta branch such as `beta` has to exist in Steamworks → SteamPipe → Builds first; GodotPipe checks the branch list Steam reports and stops before the export when the branch is missing.

The default branch (shown as `default` in Steamworks, called `public` in build scripts) can't be set live from here: Valve's docs say it "can not be set live automatically", and on a released game Steam refuses it with `Access Denied` only after every depot is uploaded. GodotPipe therefore rejects both `default` and `public` before it starts the export. To ship a build on the default branch, upload with the field empty, then set it live in Steamworks → Builds (the **Builds** button under the field opens it); for a released app Steam asks you to confirm in the Steam Mobile app. The account needs a phone number or the mobile app attached, and any change to the account's email or phone number blocks setting builds live for 3 days. Details: https://partner.steamgames.com/doc/sdk/uploading

## Steam Guard

Normal flow: enter your username and password and press **Sign in**. With the Steam mobile app authenticator you can either type the current code into the Steam Guard code field first (it is passed to SteamCMD with `+set_steam_guard_code`, so no phone prompt is sent) or leave it empty and approve the sign-in in the Steam mobile app when SteamCMD reports `Waiting for confirmation`; the app shows **Approve in the Steam mobile app…** meanwhile. You can also type the code while it waits (or at any point during a sign-in) and press **Submit code**: the app restarts SteamCMD with the code, so you do not have to wait for the confirmation to time out. With email Guard, leave the field empty: once the password is accepted Steam sends the email and SteamCMD usually exits with `Account Logon Denied`. The app then tells you a code is needed and focuses the Steam Guard code field. Type the code and press **Sign in** again. A wrong code is reported the same way, with the field marked red so you can correct it. SteamCMD caches the session after a successful sign-in, so later uploads usually do not ask for a code again; the code field is cleared and should stay empty. On macOS and Linux the app runs SteamCMD with its own `HOME` (`user://steamcmd_home`), because SteamCMD otherwise shares its config folder with the Steam desktop client, which throws the cached session away every time it logs in. If SteamCMD still asks for the password or a code (the session expired, or the account changed), the app drops the "Signed in" state until the next successful sign-in, depot fetch or upload. To switch accounts or start over, press **Sign out** next to **Sign in**: it deletes SteamCMD's cached session (`config.vdf` in the app-owned folders) and forgets the verified state, but keeps the password and shared secret fields.

If SteamCMD instead keeps running and prompts for the code on the console, the button turns into **Submit code**: type the code and press Enter or **Submit code** and SteamCMD finishes the login in the same session. Both paths also apply while Build & Publish and a depot fetch run.

The shared secret field is optional and for advanced use only. It is the **Shared secret** field in the Steam account card. If you already have a Steam Guard `shared_secret` for a dedicated build account with publish access, you can paste it in and the app will generate codes itself. Do not set up an authenticator on your main account for this. The secret is only saved when **Remember** next to it is on.

The password and shared secret are never written to a settings file. With **Remember** on they go to the system's credential store: the login Keychain on macOS (items named `GodotPipe`), DPAPI on Windows (an encrypted value in `user://secrets.cfg` that only your Windows user account can decrypt), and the Secret Service on Linux (GNOME Keyring or KWallet through `secret-tool`). On Linux without `secret-tool` or a running keyring, **Remember** is turned off and the fields are only kept until you quit. With **Remember** off they are only kept in memory. Older versions saved them as plain text in `user://settings.cfg`; the app moves them to the credential store on the next start and removes them from the file. The password is also never put on SteamCMD's command line, where other programs could read it: the app types it in when SteamCMD asks for it.

## Platform notes

The app runs on macOS, Windows and Linux; the export presets build all three. SteamCMD is an Intel 32-bit binary from Valve, so the host needs: on Apple Silicon Macs, Rosetta (`softwareupdate --install-rosetta`); on Linux, the 32-bit runtime (`sudo apt install lib32gcc-s1` on Debian/Ubuntu, `sudo dnf install glibc.i686 libstdc++.i686` on Fedora, `lib32-gcc-libs` from multilib on Arch) and `tar` on `PATH` for the **Download SteamCMD** button; on Windows, nothing extra (`steamcmd.exe` is unpacked with Godot's own zip reader). macOS exports are unpacked with `unzip` when it is on `PATH`; otherwise the app unpacks them itself and marks the bundle's binaries executable where the OS allows it. Windows can't, so build macOS depots on a Mac (or on Linux with `unzip`); the app warns when a macOS build lost its executable bits. Godot and SteamCMD are looked up on `PATH`, in the usual install folders of each OS and in every Steam library; the **Find** buttons and the file pickers cover anything else.
