# QuickPeek
This plugin allows you to spectate other players while being alive so your gameplay will not be interrupted.  
It can be useful for gamemodes where it's not against the rules to have info on other players' movement.  
It can make it more fun in turn-based gamemodes like trikz: oftentimes your gameplay depends on your partner's actions, so it's not that fun having to just wait for the partner to complete some sub-level in an obscured area where you cannot see their progress - and this is exactly what this plugin is to address, i.e. by enabling you to observe their actions first-person.

[You can take a look at the video to get idea of the plugin.](https://www.youtube.com/watch?v=ZoUhiFdZ-2g)

At the moment, there may be a problem with the sounds while peeking.  
***You can't peek fakeplayers and bots.***

Plugin was tested only in CS:S but the concept should work in any other game (may need to update offsets).

# Installation
At least SourceMod **1.11.0.6822** is requred.

Simply place **quickpeek.smx** and **quickpeek.games.txt** in  
*addons/sourcemod/plugins* and *addons/sourcemod/gamedata* folders respectively.

Also, there is v34 (CS:S, Linux) game data file. Remove the **"_v34"** postfix after placing.

*It is recommended to set high network rates (especially **sv_minupdaterate** and **sv_maxupdaterate** cvars) to improve usability of the plugin.*

# Usage
There are two in-game console commands differing in just their usage:

**qpeek** - toggle peeking, i.e. you'd stop peeking once you press the corresponding button once more;  
**+qpeek** - start peeking, i.e. the peeking would stop as soon as you release the corresponding button.

It is recommended to bind one of them.

While peeking, you retain the ability to move, you can switch targets using mouse buttons (+attack/+attack2) and you can see the current target displayed at the bottom half of the screen. It remembers the last used target when peeking again.

It follows standard interpolation settings, and to reduce latency, set low interpolation values.

Also, there is additional **qpeek angles** sub-command to turn on/off turning your player.  
It is disabled by default.

# Technical Details
This plugin uses *replay system* that allows you to literally take place of any player by receiving the same frames that were generated for them.

There is **sv_maxreplay** cvar which determines the number of seconds the engine keeps for replaying.  
Since the idea of the plugin is real-time peeking, the plugin, with some excess, sets this cvar to **1.0** and forces to send only the most recent frames.  
But in order to drastically change the flow of frames later, need to fully update game information on the client. And it needs to send a lot of data quickly.  
Setting high updaterate will help you to increase speed of this.

# Links
[Demonstration](https://www.youtube.com/watch?v=ZoUhiFdZ-2g)  
[AlliedModders](https://forums.alliedmods.net/showthread.php?p=2801529)
