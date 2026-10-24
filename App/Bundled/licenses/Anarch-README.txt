== ANARCH for the Nintendo 3DS ==

A straightforward port of Miloslav Ciz's Anarch to the Nintendo 3DS, powered by devkitpro.

Anarch is a suckless, anarcho-pacifist FPS game made with portability and simplicity in mind. It's recieved ports official and unofficial to several platforms and has gotten some attention in select spots on the Internet. I was moved, probably for the wrong reasons, by a particular port (and monetization) of the game to the Ninteno Switch to make this and several other homebrew ports, including those for (in order of completeness / functionality) the Nintendo DS, the Wii U, the GameCube and Wii, the GBA, and the N64. Yes, I was going to do a Switch port as well, but I have neither an emulator that works on my PC nor a jailbroken Switch.

This is FREE SOFTWARE, distributed with NO WARRANTY and released under the terms of the Creative Commons Zero waiver plus an additional waiver of additional rights. You may find the source code to this port and other homebrew ports of the game I made here: https://codeberg.org/blitzdoughnuts/Anarch_DEVKIT

Tested on the Manderine emulator (GNU/Linux x86_64 appimage) and on a softmodded 3DS.

== STATUS ==

Inputs and graphics are working flawlessly, although there's frame drops in busy areas that only go down to ~30 FPS, and generally it's otherwise perfect. Audio is choppy, for some reason--at least to my understanding--the PCM16 buffer fills aren't repeating fast enough, and/or just leave blank space, leading to shoddy audio. It's best to just turn it off if you don't like dealing with semi-comprehensible audio.

== INSTALLING ==

Simply drop the .3dsx file into your sdmc:/3ds/ folder, and the Homebrew Menu should find it.

== CONTROLS ==

D-pad and joystick - Move forward and backward, turn left and right
A - Fire, confirm
B - Hold to strafe and look up/down
X + UP or Y - Jump
L/R or X + LEFT/RIGHT - Cycle previous / next weapon
SELECT - View map
START or X + UP - Menu

You can tap the touch screen to get a controls list.
