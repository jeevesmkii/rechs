#!/usr/bin/perl
# Copyright © 2016 Chris Davies <cdavies@28.8bpsmodem.com>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or
# implied warranty.
#

use strict;
use warnings;
use Env qw(APPDATA);
use POSIX qw(strftime);
use POE;
use Win32::API;
use Win32::API::Callback;
use File::Path;
use File::stat;
use Fcntl ':mode';
use Time::HiRes;
use File::Copy;
use Data::Dumper;
use FindBin::Real;

use constant SCRIPT_PATH => FindBin::Real::Bin();
use lib SCRIPT_PATH . "/lib";
use Hearthstone::GameState;

# ** Begin Configuration **

# The directory where our recordings should be saved, you should probably change this.
my $hs_recordings_dir = "C:\\Temp\\Hearthstone";

# The root directory where Hearthstone is installed
my $hs_root = "C:\\Program Files (x86)\\Hearthstone";

# The root directory where OBS is installed.
my $obs_root = "C:\\Program Files\\OBS";

# The name of the OBS settings profile you are using, defaults to "Untitled"
my $obs_profile_name = "Untitled";

# Set this if OBS is in a different language and the window title doesn't contain "Open Broadcaster Software"
my $obs_title_string = "Open Broadcaster Software";

# ** End Configuration **

# Declarations for Win32 functions we need
Win32::API->Import('user32', 'GetWindowText', 'NPN', 'N');
Win32::API->Import('user32', 'EnumWindows', 'KN', 'N');
Win32::API->Import('user32', 'PostMessage', 'NNNN', 'N');

use constant {
	WM_USER => 0x400
};

my $hs_game_state = undef;
my @hs_player_classes = ();
my $obs_video_root = "";
my $obs_video_ext = "";
my $obs_handle = 0;
my ($obs_stoprec_msg_id, $obs_startrec_msg_id) = (1, 2);

my $hs_hero_map = {
	HERO_01 => "Warrior",
	HERO_02 => "Shaman",
	HERO_03 => "Rogue",
	HERO_04 => "Paladin",
	HERO_05 => "Hunter",
	HERO_06 => "Druid",
	HERO_07 => "Warlock",
	HERO_08 => "Mage",
	HERO_09 => "Priest"
};

sub find_obs_window_handle()
	{
	my $hwnd = 0;
	
	my $enum_callback = Win32::API::Callback->new(
		sub
			{
			my ($handle) = @_;
			my $title = " " x 255;
			my $len = GetWindowText($handle, $title, 255);
			$title = substr($title, 0, $len);
			
			$hwnd = $handle 
				if (index($title, $obs_title_string) != -1);
			
			return 1;
			},
		"NN", "N"
		);
	
	EnumWindows($enum_callback, 0);
	return $hwnd;
	}

sub parse_obs_profile($)
	{
	my ($profile) = @_;
	
	my $fn = $APPDATA . "\\OBS\\profiles\\" . $profile . ".ini";
	open(my $fh, "<", $fn) || die "RecHS: Could not open OBS profile $fn."; 
	
	my $message_offset = 0;
	my ($startrec_hotkey, $stoprec_hotkey) = (0, 0);
	
	my $keyvalre = qr/=(.*)$/;
	while (my $line = <$fh>)
		{
		if ($line =~ /SavePath/)
			{
			$obs_video_root = $1
				if ($line =~ $keyvalre);
			}
		elsif ($line =~ /StartRecordingHotkey/)
			{
			$startrec_hotkey = $1
				if ($line =~ $keyvalre);
			}
		elsif ($line =~ /StopRecordingHotkey/)
			{
			$stoprec_hotkey = $1
				if ($line =~ $keyvalre);
			}
		elsif ($line =~ /PushToTalkHotkey/ || $line =~ /PushToTalkHotkey2/ ||
			$line =~ /MuteMicHotkey/ || $line =~ /MuteDesktopHotkey/ ||
			$line =~ /StopStreamHotkey/ || $line =~ /StartStreamHotkey/)
			{
			!$1 || $message_offset++
				if ($line =~ $keyvalre);
			}
		}
	close($fh);
	
	$startrec_hotkey || die "RecHS: The selected OBS profile has no start recording hotkey configured.";
	$stoprec_hotkey || die "RecHS: The selected OBS profile has no stop recording hotkey configured.";
	($obs_video_root ne "") || die "RecHS: The selected OBS profile has no video output directory configured.";
	
	$obs_video_root =~ s/\\(\.[^\\]+)$//;
	$obs_video_ext = $1;
	$obs_stoprec_msg_id += $message_offset;
	$obs_startrec_msg_id += $message_offset;
	}

sub obs_start_recording($)
	{
	my ($obs_handle) = @_;
	
	PostMessage($obs_handle, WM_USER+2, 1, $obs_startrec_msg_id);
	PostMessage($obs_handle, WM_USER+2, 0, $obs_startrec_msg_id);
	}
	
sub obs_stop_recording($)
	{
	my ($obs_handle) = @_;
	
	PostMessage($obs_handle, WM_USER+2, 1, $obs_stoprec_msg_id);
	PostMessage($obs_handle, WM_USER+2, 0, $obs_stoprec_msg_id);
	}
	
sub find_latest_obs_video()
	{
	opendir(my $dh, $obs_video_root) || die "RecHS: The OBS video output directory could not be opened.";
	
	my $latest_video = "";
	my $latest_ctime = 0;
	while (my $dirent = readdir($dh))
		{
		my $fstat = stat($obs_video_root . "\\" . $dirent);
		
		if ($fstat->mode & S_IFREG)
			{
			if ($fstat->ctime > $latest_ctime)
				{
				$latest_video = $dirent;
				$latest_ctime = $fstat->ctime;
				}
			}
		}
	closedir($dh);
	
	return $latest_video;
	}

sub hs_gamestate_cb($)
	{
	my ($event) = @_;
	
	if ($event->{event_type} == Hearthstone::GameState::HS_GAME_EVENT_NEW_GAME)
		{
		@hs_player_classes = ();
		obs_start_recording($obs_handle);
		}
	elsif ($event->{event_type} == Hearthstone::GameState::HS_GAME_EVENT_TURN_STARTED)
		{
		# when the first turn starts, save the player classes before any hero transforms happen.
		if (scalar(@hs_player_classes) == 0)
			{
			my $hs_game = $hs_game_state->get_game_state();
			my $player1 = $hs_game_state->get_entity($hs_game->{players}->{1});
			my $player2 = $hs_game_state->get_entity($hs_game->{players}->{2});
			
			my $player1_hero = $hs_game_state->get_entity($player1->{hero});
			my $player2_hero = $hs_game_state->get_entity($player2->{hero});
			
			my $hero_card1 = $player1_hero->{entity_card_id};
			my $hero_card2 = $player2_hero->{entity_card_id};
			$hero_card1 =~ s/[a-z]$//;
			$hero_card2 =~ s/[a-z]$//;
		
			@hs_player_classes = (
				$hs_hero_map->{$hero_card1},
				$hs_hero_map->{$hero_card2}
				);
			}
		}
	elsif ($event->{event_type} == Hearthstone::GameState::HS_GAME_EVENT_GAME_COMPLETE)
		{
		my $hs_game = $hs_game_state->get_game_state();
		my $player1 = $hs_game_state->get_entity($hs_game->{players}->{1});
		my $player2 = $hs_game_state->get_entity($hs_game->{players}->{2});
		
		# wait a couple of seconds for the endgame to play out before we stop the recording
		Time::HiRes::usleep(5000000);
		obs_stop_recording($obs_handle);
		
		# give OBS another couple of seconds to finish up
		Time::HiRes::usleep(2000000);
		
		# discard matches that ended before the first turn (e.g. opponent disconnected in matchmaking)
		if (scalar(@hs_player_classes) != 0)
			{
			my $opponent_name = "Unknown";
			my $match = "";
			my $outcome = "Won";
			if ($player1->{is_local})
				{
				$match = $hs_player_classes[0] . " vs. " . $hs_player_classes[1];
				$opponent_name = $player2->{entity_name};
				$outcome = "Lost"
					if ($player1->{tags}->{PLAYSTATE} eq "LOST");
				}
			else
				{
				$match = $hs_player_classes[1] . " vs. " . $hs_player_classes[0];
				$opponent_name = $player1->{entity_name};
				$outcome = "Lost"
					if ($player2->{tags}->{PLAYSTATE} eq "LOST");
				}
			
			my $destfolder = $hs_recordings_dir . "\\" . strftime("%Y-%m-%d", localtime());
			my $destname = "$match, against $opponent_name ($outcome) " . strftime("%H-%M-%S", localtime()) . $obs_video_ext;
			File::Path::make_path($destfolder);
			
			my $recording = find_latest_obs_video();
			File::Copy::move($obs_video_root . "\\" . $recording, $destfolder . "\\" . $destname);
			}
		
		@hs_player_classes = ();
		}
	}
	
sub hs_gamestate_error($)
	{
	my ($error) = @_;
	
	# since the library doesn't actually handle errors yet....
	}

print "RecHS: Running.\n";

parse_obs_profile($obs_profile_name);

# launch OBS and find its window handle
system(1, "\"$obs_root\\OBS.exe\" -profile \"$obs_profile_name\"");

my $retries = 3;
while ($obs_handle == 0)
	{
	Time::HiRes::usleep(2000000);
	$obs_handle = find_obs_window_handle();
	
	last
		if ($retries-- <= 0);
	}

($obs_handle != 0) || die "RecHS: Failed to start OBS or find its running windows."; 

# ensure the recordings dir exists.
File::Path::make_path($hs_recordings_dir);

$hs_game_state = Hearthstone::GameState->new($hs_root . "\\Logs", \&hs_gamestate_cb, \&hs_gamestate_error);
POE::Kernel->run();