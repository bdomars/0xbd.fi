---
title: "Squad mortar script"
date: 2017-05-08T19:19:36+03:00
draft: false
slug: "squad-mortar-script"
github: "bdomars/mortar-py"
tags: ["squad", "python"]
categories: ["projects"]
---

A while back I started playing [Squad](https://joinsquad.com/), a tactical
shooter that leans more towards milsim than games like Battlefield, but
still keeps spawning and gameplay more arcade-like than full-on milsims such
as ArmA. It's a lot of fun and very teamplay oriented.

Right around the time I started playing, mortars were added to the game.
Aiming them by hand gets tedious, so I wrote a small Python script to do
the math for me.

## Grid references

The map in Squad is divided into a grid of 300 meter squares, with letters
along one axis and numbers along the other, so you give positions like A5 or
C8.

For more precision you add a keypad: imagine the square split into a 3×3
grid, numbered like the keys on a numeric keypad. B6 keypad 4 means the
middle row, left side of B6. You can keep going and split a keypad cell into
another 3×3 grid for even finer positions.

## Aiming a mortar

A mortar is aimed with two numbers: a direction in degrees and an elevation
in mils. You can get rough estimates with the in-game map markers, but if you
already know where you are and where the target is, the rest is just a bit
of trigonometry. So why not let a script do it?

## How the script works

1. **Grid reference to coordinates.** A reference like `C5K7` is turned into
   a position in meters, using the center of the square and then moving
   towards each keypad in turn. Each level of keypads is a third of the size
   of the one before it.
2. **Direction.** The angle from the mortar to the target, measured clockwise
   from north.
3. **Distance.** The straight-line distance between the two points.
4. **Elevation.** The game's range table gives an elevation in mils for every
   50 meters from 50 to 1250 meters. The script fits a spline through it to
   get a value for any distance in between. Anything outside that range is
   out of reach.

## Using it

The script takes two grid references, your mortar and the target. Keypads
go after a `K`, and you can stack as many as you like (`B6K75` is keypad 7,
then keypad 5 inside that):

```
$ ./grid.py C5K7 D6K3

Targeting solution
-------------------------------
Angle      :      135.0 degrees
Distance   :      707.1 meters
Elevation  :     1288.5 mils

Ready to fire!
```

The script is written for Python 2 and needs numpy and scipy.

## Afterword

Since then plenty of other tools with nice user interfaces have shown up
online, but I still like being able to quickly type something on the
command line. :)
