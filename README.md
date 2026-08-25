# 2 Ship 2 Harkinian Android

Android port of 2 Ship 2 Harkinian, based on the HarbourMasters project and forked from Waterdish's original Android port.

Original repository: https://github.com/HarbourMasters/2ship2harkinian

Original port: https://github.com/Waterdish/2ship2harkinian-Android

Current Android release: **v5.0.1-android.1**

Supported: Android 7+ with OpenGL ES 3.0+

Tested on: Android 13

## Installation

1. Install the APK from the releases page: https://github.com/linkzenic/2ship2harkinian-Android/releases
2. Open the app once so it can create the data folder and copy bundled support files.
3. When prompted, select your legally obtained `MM.z64` ROM so the app can generate `mm.o2r`.
4. Subsequent launches should start directly into the game.

Use the Back, Select, or minus controller button, or the Android back gesture/button, to open the 2 Ship 2 Harkinian menu. Use touch controls or a controller to navigate menus.

## Data Folder

The app stores user data in the selected 2S2H data folder. You can view the current folder and change it from Settings > General.

Mods and user preset files should be placed in the relevant folders inside the selected data folder.

## FAQs

**What is different with this fork?**
Special attention to Android specific needs.
 - Move the data folder to an SD card
 - Turn touch controls on or off
 - Scalable menu sizes

**Why is it immediately crashing?**

Try deleting and regenerating `mm.o2r` from your own ROM.

**My controller is not doing anything.**

Open the menu and check Settings > Controls to confirm the controller is detected and mapped.

**Can I hide the on-screen touch controls?**

Yes. Use Settings > Touch Controls > Disable Touch Controls.

**Can I resize the menu?**

Yes. Use Settings > General > Menu Scale.

## Known Issues

Orientation lock is limited by SDL behavior on Android: https://github.com/libsdl-org/SDL/issues/6090

Near-plane clipping can occur when the camera is close to walls.
