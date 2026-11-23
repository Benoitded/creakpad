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
   32° ┤  ...and here              "no no no"
   16° ┤  ...and here              "nooo!"
    0° ┴  shut                     (the Mac sleeps)

          open it again            "rude."
```

## Try it

```sh
curl -fsSL https://raw.githubusercontent.com/Benoitded/creakpad/main/play.sh | sh
```

It downloads one file to `~/.local/bin/creakpad` and starts it in your terminal. The script is
[play.sh](play.sh), read it first if you like. Then mute your Mac, put it on a table, and move the lid
slowly.

```text
  ▕████████████···┊·······················▏  40°  ▼ creeeak
```

## Turn it on and off

```text
creakpad              run it in this terminal, Ctrl-C to stop
creakpad on           keep it running in the background, and start it at every login
creakpad off          stop it, and stop starting it at login
```

If `creakpad` isn't found, use its full path: `~/.local/bin/creakpad on`.
To uninstall: `creakpad off`, then delete `~/.local/bin/creakpad`.

## Needs

- A MacBook with a lid angle sensor: MacBook Pro 16" (2019) and later, and most Apple silicon MacBooks.
- macOS 12 or later.

Without the sensor, it says so and stops.

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

## Make it yours

The lines, the voice and the creak's knobs sit at the top of [creakpad.swift](creakpad.swift):

```swift
let voice = "Fred"           // any voice from `say -v '?'`
let begging = [(50, "wait"), (32, "no no no"), (16, "nooo!")]
let sulk = "rude."
```

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
