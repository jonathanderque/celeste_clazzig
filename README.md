# Celeste Clazzig

This is a Zig source port of the [original celeste (Celeste classic)](https://www.lexaloffle.com/bbs/?tid=2145) for the PICO-8.

# Status

This is work in progress:

* the game can be fully played from start to finish, with either keyboard or controller
* sound (both music and sfx) needs to be reworked/improved
* the code itself could be reworked to be cleaner and more idiomatic

# Installation

The game requires Zig v0.11.0 and SDL2 installed.

The game also needs the original game cart from which sounds and graphics are extracted. The cart can be downloaded by running:

```shell
zig build download-cart
```

The game can then be built and run with:

```shell
zig build run
```

At this point, this has only be tested on Linux.

# Controls

* Keyboard controls
** arrows to move
** Z to jump (Z assumes a qwerty keyboard. On non-qwerty keyboards this is the left-most letter key on the bottom row)
** X to dash (letter key next to the jump key on non-qwerty keyboards)
** Escape to invoke the Pause menu

* Gamepad controls should be self explicit. X-Input gamepads work well. Dualshock 4 controllers work partially (the game can be played but the option menu is not working).

# Credits

* Developers (Maddy Thorson & Noel Berry) of the original PICO-8 game.
* [`ccleste`](https://github.com/lemon32767/ccleste/) and [Celeste Classic](https://github.com/NoelFB/Celeste/blob/master/Source/PICO-8/Classic.cs)(as embedded in the commercial Celeste game) were used as reference implementation for the game itself.
* [`pemsa`](https://github.com/egordorichev/pemsa) and [`zepto8`](https://github.com/samhocevar/zepto8) were used as reference implementation for the audio engine.


