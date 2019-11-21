---
title: "Squad mortar script"
date: 2019-11-21T15:54:33+02:00
draft: true
github: "bdomars/mortar-py"
tags: ["squad"]
categories: ["projects"]
---

So a quite a while back I started playing Squad. Squad is a tactical shooter leaning more towards the milsim category than series such as Battlefield but still keeping more of an arcady approach to spawning and gamplay than full out milsims like ArmA. All in all it's a very fun extremely teamplay oriented game.

The map in Squad is divided into a grid system with letters and numbers and so you give coordinates like A5 or C8. For enhanced precision you can also specify a keypad like B6 keypad 4. This means you should imagine the grid cell referenced, B6, as divided into a still smaller 3x3 grid where each sub grid cell is labeled as the numbers on your keypad. So keypad 4 would be middle row, left side.

A new feature that was added right around the time I started playing was mortars. Mortars are aimed with a direction in degrees and a vertical angle given in mils. Usually you can use in-game markers to get rough estimates for these numbers but I figured you could just give very precise grid references to a script, do some trigonometry and have the script spit out your angles.

Since then there have appeared plenty of other online versions with nice user interfaces, but I still like being able to just quickly type something on a command line. :)
