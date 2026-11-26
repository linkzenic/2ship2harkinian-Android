# 2 Ship 2 Harkinian Ports

Android, iOS, and tvOS ports of 2 Ship 2 Harkinian, based on the HarbourMasters
project and Waterdish's original Android port. All three downloads are published
together on the [releases page](https://github.com/linkzenic/2ship2harkinian-Ports/releases).

Original repository: [https://github.com/HarbourMasters/2ship2harkinian
](https://github.com/2ship2harkinian/2ship2harkinian)

Public iOS and tvOS IPAs are unsigned and do not include game data. Sign them
with your own setup before installing. When updating, reuse the same app
identifier and signing setup so your data remains available.

[Controller HUD presets and artwork credits](docs/controller-hud.md)

## iPhone and iPad setup

1. On a computer, use a compatible desktop build of 2 Ship 2 Harkinian to generate
   `mm.o2r` from your own supported Majora's Mask ROM.
2. Sign and sideload the iOS IPA, and make your `mm.o2r` available in the Files app.
3. Open 2 Ship, tap **Import mm.o2r**, and select the generated archive. The app
   copies it into its own data folder. It does not generate the archive on iOS.

If your own signed IPA already contains `mm.o2r`, or the file is already in the
app's Documents folder, 2 Ship skips import. The public IPA includes the
`2ship.o2r` support archive, but not `mm.o2r`.

## Apple TV setup

Generate `mm.o2r` on a computer. Include it in your own IPA before signing, or
install the app and choose **Start File Transfer** at first launch. Follow the
on-screen directions from a phone or computer on the same local network.

iCloud sync on iOS and tvOS requires an iCloud-enabled build and compatible
signing and iCloud configuration.

## Android

Supported: Android 7+ with OpenGL ES 3.0+

Tested on: Android 13

## Installation

1. Install the APK from the [releases page](https://github.com/linkzenic/2ship2harkinian-Ports/releases).
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
