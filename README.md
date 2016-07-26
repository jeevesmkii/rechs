# RecHS: A script for individually recording Hearthstone games.

Caveat: This is a major hack I made mostly as a debugging tool for a larger script I'm currently working on. The library it
uses for listening to what Hearthstone is doing is currently incomplete and may stop working abruptly if it encounters something
it doesn't understand. The method it uses to talk to OBS is pure evil. This script basically works. For me. On my computer. On a full moon. In a rainstorm. If you have any
problems I'll try to help, but no guarantees.

## Requirements

This script will only work on Windows machines. It requires the following:

* A perl interpreter, ActivePerl is good. (http://www.activestate.com/activeperl)
* The following perl modules from CPAN:
	* Win32::API
	* POE
* OBS classic (https://obsproject.com/) This will probably NOT work with the newer OBS studio, or if it does it's a massive coincidence.  


## Setting up

First, step a scene in OBS you want to record (typically just a window capture of the Hearthstone window, but you
could also include webcam capures, overlays, etc.) and do a test recording. Then you will need to set hotkeys for
"Start Recording" and "Stop Recording." It doesn't matter what the hotkeys are, as long as they exist. Make a note of
name of your settings profile (defaults to "Untitled.") and close OBS.

Second, you must set up logging in Hearthstone. If you've installed Deck Tracker, this has been done for your automatically.
If not, follow this short guide Deck Tracker: https://github.com/HearthSim/Hearthstone-Deck-Tracker/wiki/Setting-up-the-log.config

Finally, there are a few configuration options in rechs.pl itself. You will need to tell it where you want the video
output to be stored, the directories where OBS and Hearthstone are installed and the OBS settings profile you noted down earlier.

## Running.

Double click rechs.bat and start playing Hearthstone! OBS will start automatically, and hopefully everything will work smoothly.
