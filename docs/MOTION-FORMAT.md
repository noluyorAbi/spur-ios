# motion.bin: raw motion samples of a trip

Spur 1.2 records the phone's device motion while a trip records. Each trip folder holds
`motion.bin` next to `fixes.jsonl`. Nothing in it is filtered or downsampled. The all-trips ZIP carries
it per trip, together with this description.

## Layout

All numbers are little-endian.

### Header, 32 bytes

| offset | size | type    | content                                                        |
| ------ | ---- | ------- | -------------------------------------------------------------- |
| 0      | 8    | bytes   | magic `SPURMOT` followed by a zero byte                         |
| 8      | 2    | UInt16  | format version, 1                                               |
| 10     | 2    | UInt16  | record size in bytes, 60                                        |
| 12     | 2    | UInt16  | nominal sample rate in Hz (100 or 50)                           |
| 14     | 1    | UInt8   | reference frame, 1 = CoreMotion `xArbitraryZVertical`           |
| 15     | 1    | UInt8   | reserved, 0                                                     |
| 16     | 8    | Float64 | creation time, unix seconds                                     |
| 24     | 8    | bytes   | reserved, zeros                                                 |

### Record, 60 bytes, one per sample

| offset | type    | content                                                               |
| ------ | ------- | --------------------------------------------------------------------- |
| 0      | Float64 | time, unix seconds (wall clock)                                       |
| 8      | Float32 | userAcceleration x, y, z in g (device axes, gravity removed)          |
| 20     | Float32 | gravity x, y, z in g (device axes, points to the earth)               |
| 32     | Float32 | rotationRate x, y, z in rad/s (device axes, right-hand rule)          |
| 44     | Float32 | attitude quaternion x, y, z, w                                        |

About 21.6 MB per hour at 100 Hz (60 bytes × 100 × 3600), half at 50 Hz.

## Axes and signs

- Device axes as CoreMotion defines them: x to the right of the screen, y to its top edge, z out of
  the screen, right-handed.
- `gravity` points to the earth in device axes: a phone lying face up reads (0, 0, -1).
- `userAcceleration` is MINUS the device's physical acceleration: the accelerometer reports minus
  the specific force, and `userAcceleration` is that minus `gravity`. A phone pushed upwards reads a
  negative z. Physical acceleration in m/s² is `-userAcceleration × 9.80665`.
- `rotationRate` follows the right-hand rule: turning left about the vertical is positive about
  "up" (`-gravity`).
- The device axes are the phone's, not the car's: the phone sits in its mount at an unknown angle.
  Spur derives the car's frame per trip from these samples: up from gravity, then the horizontal
  rotation fitted against the GPS speed change and the gyro times the GPS speed, per mount segment.

## Time base

CoreMotion stamps samples in seconds since the phone booted. Spur maps them to wall-clock unix
seconds with `offset = now (unix s) - system uptime`, taken once when recording starts or
resumes. A step of the wall clock during recording therefore does not move the samples; a step
before a resume shifts every later record by that step. Spur keeps the file strictly increasing
in time: a batch that would start at or before the last record is moved to just after it, with
its spacing kept.

## Reading

- The stride between records is the record size in the header (60 in version 1). Read it from the
  header rather than assuming 60, so a later version with longer records still parses.
- A record cut short at the end (the app was killed while writing) is ignored. Before Spur appends
  again after a resume, it cuts that partial record off, so the records stay aligned. A write that
  fails part-way is rolled back to the last whole batch.
- A record whose time is not later than the one before, or lies far outside the trip, is not
  plausible (a file damaged by an older build); Spur skips such records when reading.
- A pause of more than 0.5 s between samples is a sensor gap. It is never filled in on disk.

## Python example

```python
import struct
import numpy as np

data = open("motion.bin", "rb").read()
magic, (version, size, rate, frame) = data[:8], struct.unpack_from("<HHHB", data, 8)
assert magic == b"SPURMOT\0" and version == 1
fields = [("t", "<f8")] + [(n, "<f4") for n in
          ("ax", "ay", "az", "gx", "gy", "gz", "rx", "ry", "rz", "qx", "qy", "qz", "qw")]
dtype = np.dtype({"names": [n for n, _ in fields], "formats": [f for _, f in fields],
                  "offsets": [0] + [8 + 4 * k for k in range(13)], "itemsize": size})
count = (len(data) - 32) // size
records = np.frombuffer(data, dtype=dtype, count=count, offset=32)
# (-userAcceleration * g) projected on up (= -gravity):
physical_up = 9.80665 * (records["ax"] * records["gx"] + records["ay"] * records["gy"] + records["az"] * records["gz"])
```

`physical_up` is the vertical acceleration in m/s², positive up (gravity is a unit vector in g).
