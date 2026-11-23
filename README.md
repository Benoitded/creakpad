# creakpad

**Mute your Mac. Move the lid. It creaks like an old door, through the trackpad.**

A MacBook knows the angle of its lid, and its trackpad hides a small haptic motor that can make sound.
creakpad plugs one into the other. No speakers involved.

<!-- demo video: drag an .mp4 here in GitHub's editor -->

```text
  the lid                          the trackpad
  ───────                          ────────────

  130° ┬  wide open
       │
       │  move it                  creeeeak     slow: deep and loud
       │                                        fast: high and thin
   50° ┤  close it past here       "wait"
   33° ┤  ...and here              "no no no"
   16° ┤  ...and here              "nooo!"
    0° ┴  shut                     (the Mac sleeps)

          open it again            "rude."
```

## Try it

1. Open **Terminal** (press ⌘ Space, type `Terminal`, press Enter).
2. Paste this line and press Enter:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/Benoitded/creakpad/main/play.sh | sh
   ```

3. Mute your Mac, put it on a table, and move the lid slowly.

```text
  ▕████████████···┊·······················▏  40°  ▼ creeeak
```

It installs one small program, `~/.local/bin/creakpad`, and starts it. Curious what that line does? It
runs [play.sh](play.sh), 30 lines you can read.

## Make it yours

Paste this in Terminal and answer the questions, no code involved:

```sh
~/.local/bin/creakpad setup
```

```text
Which voice? Try Fred, Daniel or Samantha, or Thomas and Amélie for French.
  [Fred] › Thomas

What does it say while you close the lid? Separate the lines with commas.
  [wait, no no no, nooo!] › attends, non non non, nooon !

And when you open it again?
  [rude.] › malpoli.

Keep it running, even after a restart? (yes or no)
  [no] › yes
```

## Turn it on and off

| To | Paste in Terminal |
| --- | --- |
| start it once (close the Terminal window to stop it) | `~/.local/bin/creakpad` |
| keep it running, even after a restart | `~/.local/bin/creakpad on` |
| stop it for good | `~/.local/bin/creakpad off` |
| uninstall | `~/.local/bin/creakpad off; rm ~/.local/bin/creakpad` |

## Needs

- A MacBook with a lid angle sensor: MacBook Pro 16" (2019) and later, and most Apple silicon MacBooks.
- macOS 12 or later.

Not sure about yours? Just try it: without the sensor, it says so and stops.

## How it works

```text
lid sensor ──▶ speed ──▶ creak ──▶ haptic motor ──▶ glass ──▶ sound
  degrees       °/s       buzz       trackpad        vibrates
```

- **The lid.** The angle is an ordinary HID sensor (Apple, product 0x8104), read 50 times a second in whole
  degrees. At rest it flickers between two neighbours, so the speed is the slope of a line fitted to the
  last 0.4 s: the flicker averages out, real movement shows from 4°/s.
- **The creak.** A creaky hinge is stick-slip: the wood grips, slips, grips again. The motor pulses 45 to
  170 times a second, faster as the lid moves faster, with random jitter and skipped beats, so no two creaks
  sound the same.
- **The voice.** macOS's own voice speaks the line into memory, and the motor replays its two strongest
  resonances on every pitch beat. That trick, and the motor code, come from
  [nospeaker](https://github.com/os6/nospeaker).

Everything is one Swift file, [creakpad.swift](creakpad.swift), with no dependencies.

## Build it yourself

Needs Xcode or the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/Benoitded/creakpad
cd creakpad
./build.sh                 # builds ./creakpad for Apple silicon and Intel
./creakpad --selftest      # checks the hinge maths, no hardware needed
./creakpad
```

## Caveats

- It never drives the motor past its normal maximum strength.
- The trackpad motor is driven through MultitouchSupport, a private macOS framework, so a macOS update could
  break it.

## Thanks

- [nospeaker](https://github.com/os6/nospeaker) by Cody Collier, for making the trackpad talk. Its motor
  and voice code is reused here under the MIT license.
- [LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor) by Sam Henri Gold, for finding the lid
  sensor and the creaky door idea, through the speakers.

[MIT license](LICENSE)
