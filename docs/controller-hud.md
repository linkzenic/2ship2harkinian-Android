# Controller HUD artwork

Settings → Controller HUD lets you choose Original, Project Restoration, or
Wind Waker HD. The two new presets enable D-pad item equips without changing
the separate preference used by Original. **Use preset controller bindings** is
on by default. It temporarily replaces Player 1's gamepad button assignments
while a controller preset is visible. Uncheck it or choose Original to return
to your saved assignments. Touch, keyboard, analog sticks, and gyro are unchanged.
Button Labels only changes the display. Project Restoration offers ABXY,
BAYX, and No Letters; ZR stays labeled in either letter layout.

Both presets use X and Y for items, ZL for targeting, right stick click for Tatl
(Back if the stick cannot click), and the D-pad for its own item slots. Wind
Waker HD uses R for the third item and ZR for Shield. Project Restoration
uses ZR for the third item and R for Shield.

Project Restoration defaults to playing the Ocarina on D-pad Right once
owned. Turn off **Ocarina on D-pad Right** to use the saved item for that slot.
This does not save over the player's item assignment.
When Tatl calls, D-pad Right answers her instead. The red marker and fairy
replace the instrument prompt until the call clears.

Both presets ship in the app's support archive (`2ship.o2r`) on Android, iOS,
and tvOS. No separate HUD download is needed.

- The [Project Restoration team](https://restoration.zora.re/hd-hud) created the
  HD atlas used for the button plate, outlined D-pad, Tatl prompt, and selected
  English action prompts. The ZR plate is adapted from the ReMasked in-game HUD.
- Hyrule Hysteria created the Wind Waker button artwork for
  [WWHD HUD and Gameplay for GameCube](https://gamebanana.com/mods/715287).
  The button artwork is included with permission; the game patch is not used.

Item icons and quantities normally come from the running game. As an optional
personal customization, the Project Restoration preset can read a locally
exported 512×512 Majora's Mask 3D item atlas named `restoration-instruments.png`
in the `controller-hud` folder beside `2ship2harkinian.json`. Without that file,
the preset shows the game's Ocarina icon and still plays the correct instrument.
