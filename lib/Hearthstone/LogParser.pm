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

package Hearthstone::LogParser;

use strict;
use warnings;
use POE qw(Wheel::FollowTail);

use Data::Dumper;

# Hearthstone log types
use constant {
	HS_LOG_TYPE_POWER => 1
};

# Hearthstone power log actions
use constant {
	HS_POWER_LOG_NEW_GAME => 1,
	HS_POWER_LOG_CREATE_ENTITY => 2,
	HS_POWER_LOG_TAG_CHANGE => 3,
	HS_POWER_LOG_BLOCK_START => 4,
	HS_POWER_LOG_BLOCK_END => 5,
	HS_POWER_LOG_ENTITY_CHOICES => 6,
	HS_POWER_LOG_UPDATE_ENTITY => 7,
	HS_POWER_LOG_PREPARE_HISTORY_LIST => 8,
	HS_POWER_LOG_END_TASK_LIST => 9,
	HS_POWER_LOG_SEND_CHOICES => 10,
	HS_POWER_LOG_ENTITIES_CHOSEN => 11,
	HS_POWER_LOG_CHANGE_ENTITY => 12,
	HS_POWER_LOG_SHOW_ENTITY => 13,
	HS_POWER_LOG_HIDE_ENTITY => 14,
	HS_POWER_LOG_PRINT_OPTIONS => 15,
	HS_POWER_LOG_SEND_OPTION => 16,
	HS_POWER_LOG_METADATA => 17,
	HS_POWER_LOG_WAIT_SHOW_OPTIONS => 18,
	HS_POWER_LOG_WAIT_HIDE_OPTIONS => 19
};

# Hearthstone power log entity types
use constant {
	HS_POWER_LOG_ENTITY_GAME => 1,
	HS_POWER_LOG_ENTITY_PLAYER => 2,
	HS_POWER_LOG_ENTITY_CARD => 3
};

sub new($$$)
	{
	my ($pkg, $base_path, $log_type, $event_callback, $error_callback) = @_;

	my $self = bless {
		log_type => $log_type,
		log_metadata => {},
		
		on_action => $event_callback,
		on_error => $error_callback
		};
	
	my $log_file = "";
	
	if ($log_type == HS_LOG_TYPE_POWER)
		{
		$self->{log_metadata}->{current_action} = "";
		$self->{log_metadata}->{current_lines} = ();
		$self->{log_metadata}->{current_list} = 0;
		
		$log_file = "Power.log";
		}
	else
		{
		die("cannot initalise log parser with unknown log type.");
		}
	
	$self->{poe_session} = POE::Session->create(
		inline_states =>
			{
			_start => sub
				{
				my $fn = $base_path . "/$log_file";				

				$_[HEAP]{parent} = $self;
				$_[HEAP]{tail} = POE::Wheel::FollowTail->new(
					Filename => $fn,
					InputEvent => "got_log_line",
					ResetEvent => "got_log_rollover"
					);
				},
			got_log_line => sub
				{
				# TODO: error handling
				$_[HEAP]{parent}->_parse_log_line($_[ARG0]);
				
				if (defined($_[HEAP]{parent}->{finalised_action}))
					{	
					$_[HEAP]{parent}->{on_action}->($_[HEAP]{parent}->{finalised_action});
					undef $_[HEAP]{parent}->{finalised_action};
					}
				},
			got_log_rollover => sub
				{
				}
			}
		);
	
	return $self;	
	}

sub get_last_line($)
	{
	my ($self) = @_;
	
	return $self->{last_line};
	}

sub close($)
	{
	my ($self) = @_;
	
	# TODO
	}

# Private methods

# Log parsing regexps
use constant {
	_R_HS_LOG_TIMESTAMP => qr/^([WD] (\d+):(\d+):(\d+)\.(\d+) )/,
	_R_HS_POWERLOG_LINETYPE => qr/^((\w+)(\s+\[taskListId=(\d+)\])?.*\.(\w+)\(\) -)/
};

# Full entity logging type
use constant {
	_HS_FULL_ENTITY_CREATE => 1,
	_HS_FULL_ENTITY_UPDATE => 2
};

sub _finalise_power_log_new_game($)
	{
	my ($self) = @_;
	
	# new game actions should only have one line, and have no relevant attributes
	(scalar(@{$self->{log_metadata}->{current_lines}}) == 1) || die "power log new game action has unexpected line count.";
	
	my $new_game_line = @{$self->{log_metadata}->{current_lines}}[0];
	
	# the create game action happens twice in any given game. Ignore the second instance.
	return if ($new_game_line->{category} eq "PowerTaskList");
	
	my $action = {
		from => $new_game_line->{timestamp},
		to => $new_game_line->{timestamp},
		action_type => HS_POWER_LOG_NEW_GAME
	};
	
	$self->{finalised_action} = $action;
	}
	
sub _finalise_power_log_create_entity($)
	{
	my ($self) = @_;
	
	my $action = { action_type => HS_POWER_LOG_CREATE_ENTITY };
	my @lines = @{$self->{log_metadata}->{current_lines}};
	(scalar(@lines) > 0) || die "power log create entity action has no header line.";
	my $header = shift @lines;
	
	if ($self->{log_metadata}->{current_action} eq "GameEntity")
		{
		$action->{entity_type} = HS_POWER_LOG_ENTITY_GAME;
		$action->{entity_id} = $header->{attributes}->{EntityID};
		
		# Create game entity actions happen twice per game, treat the second instance as an update
		$action->{action_type} = HS_POWER_LOG_UPDATE_ENTITY
			if ($header->{category} eq "PowerTaskList");
		}
	elsif ($self->{log_metadata}->{current_action} eq "Player")
		{
		$action->{entity_type} = HS_POWER_LOG_ENTITY_PLAYER;
		$action->{entity_id} = $header->{attributes}->{EntityID};
		$action->{player_id} = $header->{attributes}->{PlayerID};
		$action->{game_account} = $header->{attributes}->{GameAccountId};
		
		# Create player entity actions happen twice per game, treat the second instance as an update
		$action->{action_type} = HS_POWER_LOG_UPDATE_ENTITY
			if ($header->{category} eq "PowerTaskList");
		}
	elsif ($self->{log_metadata}->{current_action} eq "FULL_ENTITY")
		{
		$action->{entity_type} = HS_POWER_LOG_ENTITY_CARD;
		$action->{entity_id} = $header->{attributes}->{ID};
		$action->{entity_card_id} = $header->{attributes}->{CardID};
		}
	else
		{
		die "power log entity create action type unknown.";
		}
	$action->{from} = $header->{timestamp};
	$action->{to} = $header->{timestamp};
	
	# add tags to the entity from the remaining lines
	$action->{tags} = {};
	while (my $tag_line = shift @lines)
		{
		(exists $tag_line->{attributes}->{tag}) || die "power log create entity action does not contain tag data.";
		(exists $tag_line->{attributes}->{value}) || die "power log create entity action does not contain value data.";
		
		$action->{tags}->{$tag_line->{attributes}->{tag}} = $tag_line->{attributes}->{value};
		$action->{to} = $tag_line->{timestamp};
		}
	
	$self->{finalised_action} = $action;
	}

sub _finalise_power_log_update_entity($)
	{
	my ($self) = @_;
	
	my @lines = @{$self->{log_metadata}->{current_lines}};
	(scalar(@lines) > 0) || die "power log update entity action has no header line.";
	my $header = shift @lines;
	
	my $action = { 
		action_type => HS_POWER_LOG_UPDATE_ENTITY,
		entity_id => $header->{attributes}->{id},
		player_id => $header->{attributes}->{player},
		play_zone => $header->{attributes}->{zone},
		zone_pos => $header->{attributes}->{zonePos},
		entity_card_id => $header->{attributes}->{cardId},
		
		from => $header->{timestamp},
		to => $header->{timestamp}
	};
	
	# optional attributes
	$action->{entity_name} = "";
	if (exists $header->{attributes}->{name})
		{ 
		$action->{entity_name} = $header->{attributes}->{name};
		}
	
	# add tags to the entity from the remaining lines
	$action->{tags} = {};
	while (my $tag_line = shift @lines)
		{
		(exists $tag_line->{attributes}->{tag}) || die "power log update entity action does not contain tag data.";
		(exists $tag_line->{attributes}->{value}) || die "power log update entity action does not contain value data.";
		
		$action->{tags}->{$tag_line->{attributes}->{tag}} = $tag_line->{attributes}->{value};
		$action->{to} = $tag_line->{timestamp};
		}
	
	$self->{finalised_action} = $action;
	}

sub _finalise_power_log_full_entity($)
	{
	my ($self) = @_;
	
	my @lines = @{$self->{log_metadata}->{current_lines}};
	(scalar(@lines) > 0) || die "power log full entity action has no header line.";
	
	if ($lines[0]->{full_entity_type} == _HS_FULL_ENTITY_CREATE)
		{
		$self->_finalise_power_log_create_entity();
		}
	else
		{	
		$self->_finalise_power_log_update_entity();
		}
	}
	
sub _finalise_power_log_debug_dump($)
	{
	my ($self) = @_;
	
	# PowerTaskList blocks seem not to have formal starts or ends, but start or end in debug dumps. Add a fake block 
	# delimiters for these.
	(scalar(@{$self->{log_metadata}->{current_lines}}) == 1) || die "power log tag debug dump action has unexpected line count.";
	my $debug_dump_line = @{$self->{log_metadata}->{current_lines}}[0];
	
	if (exists $debug_dump_line->{attributes}->{"Start"} && $debug_dump_line->{attributes}->{"Start"} eq "(null)")
		{
		my $action = {
			from => $debug_dump_line->{timestamp},
			to => $debug_dump_line->{timestamp},
			action_type => HS_POWER_LOG_BLOCK_START,
			
			block_type => "null",
			block_category => $debug_dump_line->{category},
			entity => -1
		};
	
		$self->{finalised_action} = $action;
		}
	elsif (exists $debug_dump_line->{attributes}->{"End"} && $debug_dump_line->{attributes}->{"End"} eq "(null)")
		{
		my $action = { action_type => HS_POWER_LOG_BLOCK_END };
		$self->{finalised_action} = $action;
		}
	
	# otherwise, don't pass debug dumps through to applications, they're irrelevant garbage.
	# TODO: perhaps add a flag to get verbose logging information?
	}

sub _finalise_power_log_tag_change($)
	{
	my ($self) = @_;
	
	(scalar(@{$self->{log_metadata}->{current_lines}}) == 1) || die "power log tag change action has unexpected line count.";
	my $tag_change_line = @{$self->{log_metadata}->{current_lines}}[0];
	
	my $action = {
		from => $tag_change_line->{timestamp},
		to => $tag_change_line->{timestamp},
		action_type => HS_POWER_LOG_TAG_CHANGE,
		
		entity => $tag_change_line->{attributes}->{Entity},
		tag => $tag_change_line->{attributes}->{tag},
		value => $tag_change_line->{attributes}->{value}
	};	
	
	$self->{finalised_action} = $action;
	}
	
sub _finalise_power_log_block_start($)
	{
	my ($self) = @_;
	
	(scalar(@{$self->{log_metadata}->{current_lines}}) == 1) || die "power log block start action has unexpected line count.";
	my $block_start_line = @{$self->{log_metadata}->{current_lines}}[0];
	
	my $action = {
		from => $block_start_line->{timestamp},
		to => $block_start_line->{timestamp},
		action_type => HS_POWER_LOG_BLOCK_START,
		
		block_type => $block_start_line->{attributes}->{BlockType},
		block_category => $block_start_line->{category},
		entity => $block_start_line->{attributes}->{Entity},
		effect_card_id => $block_start_line->{attributes}->{EffectCardId},
		target => $block_start_line->{attributes}->{Target},
		index => $block_start_line->{attributes}->{EffectIndex}
	};
	
	$self->{finalised_action} = $action;
	}
	
sub _finalise_power_log_block_end($)
	{
	my ($self) = @_;
	
	my $action = { action_type => HS_POWER_LOG_BLOCK_END };
	$self->{finalised_action} = $action;
	}
	
sub _finalise_power_log_entity_choices($)
	{
	my ($self) = @_;
	
	my $action = { action_type => HS_POWER_LOG_ENTITY_CHOICES };
	my @lines = @{$self->{log_metadata}->{current_lines}};
	
	(scalar(@lines) >= 2) || die "power log entity choices action has no header lines.";
	my $header = shift @lines;
	my $source = shift @lines;
	
	$action->{from} = $header->{timestamp};
	$action->{to} = $source->{timestamp};
	$action->{choice_type} = $header->{attributes}->{ChoiceType};
	$action->{player} = $header->{attributes}->{Player};
	$action->{player_id} = $header->{attributes}->{id};
	$action->{task_list_id} = $header->{attributes}->{TaskList};
	$action->{choice_count_min} = $header->{attributes}->{CountMin};
	$action->{choice_count_max} = $header->{attributes}->{CountMax};
	
	# ensure that the source line is well formed
	(exists $source->{attributes}->{Source}) || die "power log entity choice line does not contain a source entity.";
	$action->{source_entity} = $source->{attributes}->{Source};
	
	# finalise the choices
	my @entity_choices = ();
	my $entity_count = 0;
	while (my $choice = shift @lines)
		{
		my $choice_name = "Entities[$entity_count]";
		(exists $choice->{attributes}->{$choice_name}) || die "power log entity choice line does not contain an entity description.";
		
		my $entity = $choice->{attributes}->{$choice_name};
		(exists $entity->{id}) || die "power log entity choice does not contain an entity id.";
		(exists $entity->{player}) || die "power log entity choice does not contain a player id.";
		(exists $entity->{zone}) || die "power log entity choice does not contain a play zone.";
		(exists $entity->{zonePos}) || die "power log entity choice does not contain a zone position.";
		(exists $entity->{cardId}) || die "power log entity choice does not contain a card ID.";
		
		my $choice_desc = {
			entity_id => $entity->{id},
			player_id => $entity->{player},
			play_zone => $entity->{zone},
			zone_pos => $entity->{zonePos},
			entity_card_id => $entity->{cardId}
		};
		
		# optional attributes
		$choice_desc->{entity_name} = "";
		if (exists $entity->{name})
			{
			$choice_desc->{entity_name} = $entity->{name};
			}
		
		$action->{to} = $choice->{timestamp};
		push(@entity_choices, $choice_desc);
		$entity_count++;
		}
	
	$action->{entity_choices} = \@entity_choices;
	$self->{finalised_action} = $action;
	}
	
sub _finalise_power_log_history_list($)
	{
	my ($self) = @_;
	
	(scalar(@{$self->{log_metadata}->{current_lines}}) == 1) || die "power log prepare history list has unexpected line count.";
	my $history_list_line = @{$self->{log_metadata}->{current_lines}}[0];
	
	my $action = {
		from => $history_list_line->{timestamp},
		to => $history_list_line->{timestamp},
		action_type => HS_POWER_LOG_PREPARE_HISTORY_LIST,
		
		task_list_id => $history_list_line->{attributes}->{m_currentTaskList}
	};
	
	$self->{finalised_action} = $action;
	}
	
sub _finalise_power_log_end_task_list($)
	{
	my ($self) = @_;
	
	(scalar(@{$self->{log_metadata}->{current_lines}}) == 1) || die "power log end task list has unexpected line count.";
	my $end_list_line = @{$self->{log_metadata}->{current_lines}}[0];
	
	my $action = {
		from => $end_list_line->{timestamp},
		to => $end_list_line->{timestamp},
		action_type => HS_POWER_LOG_END_TASK_LIST,
		
		task_list_id => $end_list_line->{attributes}->{m_currentTaskList}
	};
	
	$self->{finalised_action} = $action;
	}

sub _finalise_power_log_send_choices($)
	{
	my ($self) = @_;
	
	my $action = { action_type => HS_POWER_LOG_SEND_CHOICES };
	my @lines = @{$self->{log_metadata}->{current_lines}};
	
	(scalar(@lines) >= 1) || die "power log entity choices action has no header lines.";
	my $header = shift @lines;
	
	$action->{from} = $header->{timestamp};
	$action->{to} = $header->{timestamp};
	$action->{choice_id} = $header->{attributes}->{id};
	
	# finalise the choices
	my @entity_choices = ();
	my $entity_count = 0;
	while (my $choice = shift @lines)
		{
		my $choice_name = "m_chosenEntities[$entity_count]";
		(exists $choice->{attributes}->{$choice_name}) || die "power log entity choice line does not contain an entity description.";
		
		my $entity = $choice->{attributes}->{$choice_name};
		(exists $entity->{id}) || die "power log entity choice does not contain an entity id.";
		(exists $entity->{player}) || die "power log entity choice does not contain a player id.";
		(exists $entity->{zone}) || die "power log entity choice does not contain a play zone.";
		(exists $entity->{zonePos}) || die "power log entity choice does not contain a zone position.";
		(exists $entity->{cardId}) || die "power log entity choice does not contain a card ID.";
		
		my $choice_desc = {
			entity_id => $entity->{id},
			player_id => $entity->{player},
			play_zone => $entity->{zone},
			zone_pos => $entity->{zonePos},
			entity_card_id => $entity->{cardId}
		};
		
		# optional attributes
		$choice_desc->{entity_name} = "";
		if (exists $entity->{name})
			{
			$choice_desc->{entity_name} = $entity->{name};
			}
		
		$action->{to} = $choice->{timestamp};
		push(@entity_choices, $choice_desc);
		$entity_count++;
		}
	
	$action->{entity_choices} = \@entity_choices;
	$self->{finalised_action} = $action;
	}
	
sub _finalise_power_log_entities_chosen($)
	{
	my ($self) = @_;
	
	my $action = { action_type => HS_POWER_LOG_ENTITIES_CHOSEN };
	my @lines = @{$self->{log_metadata}->{current_lines}};
	
	(scalar(@lines) >= 1) || die "power log entities chosen action has no header lines.";
	my $header = shift @lines;
	
	$action->{from} = $header->{timestamp};
	$action->{to} = $header->{timestamp};
	$action->{player_name} = $header->{attributes}->{Player};
	$action->{player_id} = $header->{attributes}->{id};
	$action->{entities_chosen} = $header->{attributes}->{EntitiesCount};
	
	# finalise the choices
	my @entity_choices = ();
	my $entity_count = 0;
	while (my $choice = shift @lines)
		{
		my $choice_name = "Entities[$entity_count]";
		(exists $choice->{attributes}->{$choice_name}) || die "power log entities chosen line does not contain an entity description.";
		
		my $entity = $choice->{attributes}->{$choice_name};
		(exists $entity->{id}) || die "power log entity choice does not contain an entity id.";
		(exists $entity->{player}) || die "power log entity choice does not contain a player id.";
		(exists $entity->{zone}) || die "power log entity choice does not contain a play zone.";
		(exists $entity->{zonePos}) || die "power log entity choice does not contain a zone position.";
		(exists $entity->{cardId}) || die "power log entity choice does not contain a card ID.";
		
		my $choice_desc = {
			entity_id => $entity->{id},
			player_id => $entity->{player},
			play_zone => $entity->{zone},
			zone_pos => $entity->{zonePos},
			entity_card_id => $entity->{cardId}
		};
		
		# optional attributes
		$choice_desc->{entity_name} = "";
		if (exists $entity->{name})
			{
			$choice_desc->{entity_name} = $entity->{name};
			}
		
		$action->{to} = $choice->{timestamp};
		push(@entity_choices, $choice_desc);
		$entity_count++;
		}
	
	$action->{entity_choices} = \@entity_choices;
	$self->{finalised_action} = $action;
	}

sub _finalise_power_log_change_entity($)
	{
	my ($self) = @_;
	
	my @lines = @{$self->{log_metadata}->{current_lines}};
	(scalar(@lines) > 0) || die "power log change entity action has no header line.";
	my $header = shift @lines;
	
	my $action = { 
		action_type => HS_POWER_LOG_CHANGE_ENTITY,
		entity_card_id => $header->{attributes}->{CardID},
		
		from => $header->{timestamp},
		to => $header->{timestamp}
	};
	
	# so far, I've only ever seen full entity descriptions from change entity lines.
	my $entity_desc = $header->{attributes}->{Entity};
	
	(exists $entity_desc->{id}) || die "power log change entity action does not contain an entity ID.";
	(exists $entity_desc->{player}) || die "power log change entity action does not contain a player ID.";
	(exists $entity_desc->{zone}) || die "power log change entity action does not contain a play zone.";
	(exists $entity_desc->{zonePos}) || die "power log change entity action does not contain a zone position.";
	
	$action->{entity_id} = $entity_desc->{id};
	$action->{player_id} = $entity_desc->{player};
	$action->{play_zone} = $entity_desc->{zone};
	$action->{zone_pos} = $entity_desc->{zonePos};
	
	# optional attributes
	$action->{entity_type} = "";
	if (exists $entity_desc->{type})
		{
		$action->{entity_type} = $entity_desc->{type};
		}
		
	# add tags to the entity from the remaining lines
	$action->{tags} = {};
	while (my $tag_line = shift @lines)
		{
		(exists $tag_line->{attributes}->{tag}) || die "power log change entity action does not contain tag data.";
		(exists $tag_line->{attributes}->{value}) || die "power log change entity action does not contain value data.";
		
		$action->{tags}->{$tag_line->{attributes}->{tag}} = $tag_line->{attributes}->{value};
		$action->{to} = $tag_line->{timestamp};
		}
	
	$self->{finalised_action} = $action;
	}

sub _finalise_power_log_show_entity($)
	{
	my ($self) = @_;
	
	my @lines = @{$self->{log_metadata}->{current_lines}};
	(scalar(@lines) > 0) || die "power log show entity action has no header line.";
	my $header = shift @lines;
	
	my $action = { 
		action_type => HS_POWER_LOG_SHOW_ENTITY,
		entity_card_id => $header->{attributes}->{CardID},
		
		from => $header->{timestamp},
		to => $header->{timestamp}
	};
	
	# confusingly, the Entity attribute may be a full entity or just an entity ID
	if (ref($header->{attributes}->{Entity}) eq "HASH")
		{
		my $entity_desc = $header->{attributes}->{Entity};
		
		(exists $entity_desc->{id}) || die "power log show entity action does not contain an entity ID.";
		(exists $entity_desc->{player}) || die "power log show entity action does not contain a player ID.";
		(exists $entity_desc->{zone}) || die "power log show entity action does not contain a play zone.";
		(exists $entity_desc->{zonePos}) || die "power log show entity action does not contain a zone position.";
		
		$action->{entity_id} = $entity_desc->{id};
		$action->{player_id} = $entity_desc->{player};
		$action->{play_zone} = $entity_desc->{zone};
		$action->{zone_pos} = $entity_desc->{zonePos};
		
		# optional attributes
		$action->{entity_type} = "";
		if (exists $entity_desc->{type})
			{
			$action->{entity_type} = $entity_desc->{type};
			}
		}
	else
		{
		$action->{entity_id} = $header->{attributes}->{Entity};
		}
	
	# add tags to the entity from the remaining lines
	$action->{tags} = {};
	while (my $tag_line = shift @lines)
		{
		(exists $tag_line->{attributes}->{tag}) || die "power log show entity action does not contain tag data.";
		(exists $tag_line->{attributes}->{value}) || die "power log show entity action does not contain value data.";
		
		$action->{tags}->{$tag_line->{attributes}->{tag}} = $tag_line->{attributes}->{value};
		$action->{to} = $tag_line->{timestamp};
		}
	
	$self->{finalised_action} = $action;
	}
	
sub _finalise_power_log_hide_entity($)
	{
	my ($self) = @_;
	
	(scalar(@{$self->{log_metadata}->{current_lines}}) == 1) || die "power log hide entity action has unexpected line count.";
	my $hide_entity = @{$self->{log_metadata}->{current_lines}}[0];
	
	my $action = { 
		action_type => HS_POWER_LOG_HIDE_ENTITY,
		
		tags => {
			$hide_entity->{attributes}->{tag} => $hide_entity->{attributes}->{value}
		},
		
		from => $hide_entity->{timestamp},
		to => $hide_entity->{timestamp}
	};
	
	# rarely, entity will just be just an entity ID
	my $entity_desc = $hide_entity->{attributes}->{Entity};
	
	if (ref($entity_desc) eq "HASH")
		{
		# verify we've got a complete entity description
		
		(exists $entity_desc->{id}) || die "power log hide entity action does not contain an entity ID.";
		(exists $entity_desc->{player}) || die "power log hide entity action does not contain a played ID.";
		(exists $entity_desc->{cardId}) || die "power log hide entity action does not contain a card ID.";
		(exists $entity_desc->{zone}) || die "power log hide entity action does not contain a play zone.";
		(exists $entity_desc->{zonePos}) || die "power log hide entity action does not contain a zone position.";
		
		$action->{entity_id} = $entity_desc->{id};
		$action->{player_id} = $entity_desc->{player};
		$action->{entity_card_id} = $entity_desc->{cardId};
		$action->{play_zone} = $entity_desc->{zone};
		$action->{zone_pos} = $entity_desc->{zonePos};
		
		# optional attributes
		$action->{entity_name} = "";
		if (exists $entity_desc->{name})
			{
			$action->{entity_name} = $entity_desc->{name};
			}
		}
	else
		{
		$action->{entity_id} = $entity_desc;
		}
	
	$self->{finalised_action} = $action;
	}

sub _finalise_power_log_print_options($)
	{
	my ($self) = @_;
	
	my @lines = @{$self->{log_metadata}->{current_lines}};
	(scalar(@lines) > 0) || die "power log print options action has no header line.";
	my $header = shift @lines;
	
	my $action = { 
		action_type => HS_POWER_LOG_PRINT_OPTIONS,
		options_id => $header->{attributes}->{id},
		
		from => $header->{timestamp},
		to => $header->{timestamp}
	};
	
	# add the options to the finalised action
	$action->{options} = ();
	
	while (my $option_line = shift @lines)
		{
		$action->{to} = $option_line->{timestamp};
		($option_line->{option_type} eq "option") || die "power log print options action contains malformed option description.";
		
		my $current_option = { 
			option_type => $option_line->{attributes}->{type},
			targets => [],
			sub_options => []
		};
		
		if (ref($option_line->{attributes}->{mainEntity}) eq "HASH")
			{
			my $entity = $option_line->{attributes}->{mainEntity};
			
			(exists $entity->{id}) || die "power log print options action does not contain an entity ID.";
			(exists $entity->{player}) || die "power log print options action does not contain a player ID.";
			(exists $entity->{cardId}) || die "power log print options action does not contain a card ID.";
			(exists $entity->{zone}) || die "power log print options action does not contain a play zone.";
			(exists $entity->{zonePos}) || die "power log print options action does not contain a zone position.";
			
			$current_option->{entity_id} = $entity->{id};
			$current_option->{player_id} = $entity->{player};
			$current_option->{entity_card_id} = $entity->{cardId};
			$current_option->{play_zone} = $entity->{zone};
			$current_option->{zone_pos} = $entity->{zonePos};
			
			# optional attributes
			$current_option->{entity_name} = "";
			if (exists $entity->{name})
				{
				$current_option->{entity_name} = $entity->{name};
				}
			}
		else
			{
			$current_option->{entity_id} = $option_line->{attributes}->{mainEntity};
			}
			
		while ($option_line = shift @lines)
			{
			if ($option_line->{option_type} eq "option")
				{
				unshift(@lines, $option_line);
				last;
				}
			
			my $target_entity = $option_line->{attributes}->{entity};
				
			(exists $target_entity->{id}) || die "power log print options action does not contain an entity ID.";
			(exists $target_entity->{player}) || die "power log print options action does not contain a player ID.";
			(exists $target_entity->{cardId}) || die "power log print options action does not contain a card ID.";
			(exists $target_entity->{zone}) || die "power log print options action does not contain a play zone.";
			(exists $target_entity->{zonePos}) || die "power log print options action does not contain a zone position.";
			
			my $target = {
				entity_id => $target_entity->{id},
				player_id => $target_entity->{player},
				entity_card_id => $target_entity->{cardId},
				play_zone => $target_entity->{zone},
				zone_pos => $target_entity->{zonePos},
				entity_name => ""
			};	
			
			# optional attributes
			if (exists $target_entity->{name})
				{
				$target->{entity_name} = $target_entity->{name};
				}
			
			 if ($option_line->{option_type} eq "subOption")
				{
				push(@{$current_option->{sub_options}}, $target);
				}
			elsif ($option_line->{option_type} eq "target")
				{
				push(@{$current_option->{targets}}, $target);
				}
			else
				{
				die "power log print options action contains an unrecognised line.";
				}
				
			$action->{to} = $option_line->{timestamp};
			}
		
		push(@{$action->{options}}, $current_option);
		}
	
	$self->{finalised_action} = $action;
	}
	
sub _finalise_power_log_send_option($)
	{
	my ($self) = @_;
	
	(scalar(@{$self->{log_metadata}->{current_lines}}) == 1) || die "power log send options action has unexpected line count.";
	my $send_options = @{$self->{log_metadata}->{current_lines}}[0];
	
	my $action = { 
		action_type => HS_POWER_LOG_SEND_OPTION,
		selected_option => $send_options->{attributes}->{selectedOption},
		selected_suboption => $send_options->{attributes}->{selectedSubOption},
		selected_target => $send_options->{attributes}->{selectedTarget},
		selected_pos => $send_options->{attributes}->{selectedPosition},
		
		from => $send_options->{timestamp},
		to => $send_options->{timestamp}
	};
	
	$self->{finalised_action} = $action;
	}

sub _finalise_power_log_debug_message($)
	{
	my ($self) = @_;
	
	# Again, don't pass debug messages through to the client.
	}

sub _finalise_power_log_metadata($)
	{
	my ($self) = @_;
	
	my @lines = @{$self->{log_metadata}->{current_lines}};
	(scalar(@lines) > 0) || die "power log metadata action has no header line.";
	my $header = shift @lines;
	
	my $action = { 
		action_type => HS_POWER_LOG_METADATA,
		meta => $header->{attributes}->{Meta},
		data => $header->{attributes}->{Data},
		info => $header->{attributes}->{Info},
		
		from => $header->{timestamp},
		to => $header->{timestamp}
	};
	
	# add entity info from the remaining lines
	$action->{entity_info} = ();
	my $info_count = 0;
	while (my $info_line = shift @lines)
		{
		my $info_name = "Info[$info_count]";
		(exists $info_line->{attributes}->{$info_name}) || die "power log metadata info line does not contain an entity description.";
		
		my $entity = $info_line->{attributes}->{$info_name};
		my $entity_desc = {};
		
		# rarely, info lines are just an entity ID.
		if (ref($entity) eq "HASH")
			{
			(exists $entity->{id}) || die "power metadata action does not contain an entity ID.";
			(exists $entity->{player}) || die "power metadata action does not contain a player ID.";
			(exists $entity->{cardId}) || die "power metadata action does not contain a card ID.";
			(exists $entity->{zone}) || die "power log metadata action does not contain a play zone.";
			(exists $entity->{zonePos}) || die "power log metadata action does not contain a zone position.";
						
			$entity_desc->{entity_id} = $entity->{id};
			$entity_desc->{player_id} = $entity->{player};
			$entity_desc->{entity_card_id} = $entity->{cardId};
			$entity_desc->{play_zone} = $entity->{zone};
			$entity_desc->{zone_pos} = $entity->{zonePos};
			
			# optional attributes
			$entity_desc->{entity_name} = "";
			if (exists $entity->{name})
				{
				$entity_desc->{entity_name} = $entity->{name};
				}
			}
		else
			{
			$entity_desc->{entity_id} = $entity;
			}
		
		push(@{$action->{entity_info}}, $entity_desc);
		$action->{to} = $info_line->{timestamp};
		$info_count++;
		}
	
	$self->{finalised_action} = $action;
	}

sub _finalise_power_log_wait_show_choices($)
	{
	my ($self) = @_;
	
	(scalar(@{$self->{log_metadata}->{current_lines}}) == 1) || die "power log wait then show options action has unexpected line count.";
	my $wait_show_line = @{$self->{log_metadata}->{current_lines}}[0];
	
	my $action = {
		from => $wait_show_line->{timestamp},
		to => $wait_show_line->{timestamp},
		action_type => HS_POWER_LOG_WAIT_SHOW_OPTIONS,
		
		option_list_id => $wait_show_line->{attributes}->{id}
	};
	
	$self->{finalised_action} = $action;
	}
	
sub _finalise_power_log_wait_hide_choices($)
	{
	my ($self) = @_;
	
	(scalar(@{$self->{log_metadata}->{current_lines}}) == 1) || die "power log wait then hide options action has unexpected line count.";
	my $wait_hide_line = @{$self->{log_metadata}->{current_lines}}[0];
	
	my $action = {
		from => $wait_hide_line->{timestamp},
		to => $wait_hide_line->{timestamp},
		action_type => HS_POWER_LOG_WAIT_HIDE_OPTIONS,
		
		option_list_id => $wait_hide_line->{attributes}->{id}
	};
	
	$self->{finalised_action} = $action;
	}

our $_hs_power_log_action_finalisers = {
	CREATE_GAME => \&_finalise_power_log_new_game,
	GameEntity => \&_finalise_power_log_create_entity,
	Player => \&_finalise_power_log_create_entity,
	FULL_ENTITY => \&_finalise_power_log_full_entity,
	DebugDump => \&_finalise_power_log_debug_dump,
	TAG_CHANGE => \&_finalise_power_log_tag_change,
	ACTION_START => \&_finalise_power_log_block_start,
	ACTION_END => \&_finalise_power_log_block_end,
	BLOCK_START => \&_finalise_power_log_block_start,
	BLOCK_END => \&_finalise_power_log_block_end,
	EntityChoices => \&_finalise_power_log_entity_choices,
	PrepareHistoryList => \&_finalise_power_log_history_list,
	EndCurrentTaskList => \&_finalise_power_log_end_task_list,
	SendChoices => \&_finalise_power_log_send_choices,
	EntitiesChosen => \&_finalise_power_log_entities_chosen,
	CHANGE_ENTITY => \&_finalise_power_log_change_entity,
	SHOW_ENTITY => \&_finalise_power_log_show_entity,
	HIDE_ENTITY => \&_finalise_power_log_hide_entity,
	PrintOptions => \&_finalise_power_log_print_options,
	SendOption => \&_finalise_power_log_send_option,
	ErrorDebugMessage => \&_finalise_power_log_debug_message,
	META_DATA => \&_finalise_power_log_metadata,
	WaitThenShowChoices => \&_finalise_power_log_wait_show_choices,
	WaitThenHideChoices => \&_finalise_power_log_wait_hide_choices
};

sub _parse_power_log_action_complete($)
	{
	my ($self) = @_;
	
	# finalise the current action
	unless ($self->{log_metadata}->{current_action} eq "")
		{
		(exists $_hs_power_log_action_finalisers->{$self->{log_metadata}->{current_action}})
			|| die "power log action has no finaliser.";
		
		$_hs_power_log_action_finalisers->{$self->{log_metadata}->{current_action}}($self);
		}
	
	# reset the current parser state
	$self->{log_metadata}->{current_action} = "";
	$self->{log_metadata}->{current_lines} = ();
	}

sub _parse_power_log_line_action($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# chomp left whitespace
	$$line =~ s/^\s+//;
	
	# find the next instance of whitespace or an equals sign, whichever comes first
	$$line =~ /^([^=\s]*)/;
	my $action = $1;
	
	if (length($action) != length($$line))
		{
		if (substr($$line, length($action)) =~ /^\s*=/)
			{
			# if we hit an equals, this line is attributes only, return no action.
			$action = "";
			}
		}
	
	$$line = substr($$line, length($action));
	return $action;
	}

sub _parse_power_log_line_attributes($$$)
	{
	my ($self, $line, $parser_data) = @_;
	my $original = $line; 
	my $attrs = {};
	
	for (;;)
		{
		# chomp left whitespace
		$line =~ s/^\s+//;
		
		last
			unless ($line =~ /^([^=\[\]]+)/);
		$line = substr($line, length($1));
		my $key = $1;
		
		# chomp the separator,
		# if we've reached the end of an attribute block, return the list.
		my $separator = substr($line, 0, 1);
		$line = substr($line, 1);
		last if ($separator eq "]");
		
		if ($separator eq "[")
			{
			# attempt to parse a key array index
			($line =~ /^((\d+)\]\s*=)/) || die "power log line has malformed key array index.";
			$line = substr($line, length($1));
			$key = $key . "[$2]";
			}
		
		my $value = "";
		$line =~ s/^\s+//;
		if (substr($line, 0, 1) eq "[")
			{
			# if the value is a list of attributes, parse the sublist
			$line = substr($line, 1);
			$value = $self->_parse_power_log_line_attributes($line, $parser_data);
			
			# chomp the length of the attribute list that we parsed.
			$line = substr($line, $value->{_attrs_length});
			}
		else
			{
			# read up to the next separator character, or the end of the line
			$line =~ /^([^=\]]*)/;
			$value = $1;
			
			if (length($value) == length($line))
				{
				#if we've reached the end of the line, strip right whitespace and return the value
				$line = "";
				}
			elsif (substr($line, length($value), 1) eq "=")
				{
				# we've hit the next key/value pair, find whitespace before the key element
				$value =~ /(\s+\S+)$/;
				$value = substr($value, 0, -length($1));
				
				$line = substr($line, length($value));
				}
			
			# otherwise, we're at the end of a list. Just chomp whitespace from the right of the value.
			$value =~ s/\s+$//;
			}
		
		$attrs->{$key} = $value;
		}
		
	# record the length of line that we parsed.
	$attrs->{_attrs_length} = length($original) - length($line);
	return $attrs;
	}

sub _parse_power_log_list($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	
	# lists should have a count attribute, record how many elements are in the current list
	(exists $attrs->{Count}) || die ("power log list line does not have a count attribute.");
	($self->{log_metadata}->{current_list} == 0) || die("power log has nested action lists.");
	
	$self->{log_metadata}->{current_list} = $attrs->{Count};
	}

sub _parse_power_log_create_game_action($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# no action required, sub-actions of CREATE_GAME are treated as create entity
	}
	
sub _parse_power_log_game_entity($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# Game entity actions just have an attribute list specifying their entity ID.
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	(exists $attrs->{EntityID}) || die "power log game entity missing entity ID.";
	
	$parser_data->{"attributes"} = $attrs;
	}
	
sub _parse_power_log_player($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# Player creation actions have an attribute list with EntityID, PlayerID and GameAccountId
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	(exists $attrs->{EntityID}) || die "power log player entity missing entity ID.";
	(exists $attrs->{PlayerID}) || die "power log player entity missing PlayerID.";
	(exists $attrs->{GameAccountId}) || die "power log player entity missing GameAccountID.";
	
	$parser_data->{"attributes"} = $attrs;
	}
	
sub _parse_power_log_full_entity($$$)
	{
	my ($self,  $line, $parser_data) = @_;
	
	# check what action we're performing with this entity
	$line =~ /^(\s*-\s*([^\s]+))/;
	my $action = $2;
	$line = substr($line, length($1));
	
	if ($action eq "Creating")
		{
		# entity creation actions have an ID (entity ID) and a CardID
		my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
		(exists $attrs->{ID}) || die "power log full entity creation does not have an entity ID.";
		(exists $attrs->{CardID}) || die "power log full entity creation does not have a card ID.";
		
		$parser_data->{full_entity_type} = _HS_FULL_ENTITY_CREATE;
		$parser_data->{attributes} = $attrs;
		}
	elsif ($action eq "Updating")
		{
		# entity update actions have a complete card description as a group, then a cardId as a single attribute
		# find and chomp the first character of the list before we send the line to parse_attributes
		my $idx = index($line, "[");
		($idx != -1) || die "power log full entity update has no entity description.";
		$line = substr($line, $idx+1);
		
		my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
		(exists $attrs->{id}) || die "power log full entity update has no entity id.";
		(exists $attrs->{zone}) || die "power log full entity update has no zone.";
		(exists $attrs->{zonePos}) || die "power log full entity update has no zone position";
		(exists $attrs->{cardId}) || die "power log full entity update has no card id.";
		(exists $attrs->{player}) || die "power log full entity update has no owning player.";
		
		# chomp the card description list, then parse the cardId
		$line = substr($line, $attrs->{_attrs_length});
		my $cardId = $self->_parse_power_log_line_attributes($line, $parser_data);
		(exists $cardId->{CardID}) || die "power log full entity update does not have a card ID.";
		
		# merge the card ID with the rest of the attributes
		$attrs->{CardID} = $cardId->{CardID};
		
		$parser_data->{full_entity_type} = _HS_FULL_ENTITY_UPDATE;
		$parser_data->{attributes} = $attrs;
		}
	else
		{
		die("power log line has unknown full entity action.");
		}
	}

sub _parse_power_log_change_entity($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# change entity lines have a preamble "updating" before their attribute list.
	($line =~ s/^\s*-\s*Updating//) || die "power log change entity line has missing preamble.";
	
	# we're expecting an entity and a card id.
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	(exists $attrs->{Entity}) || die "power log show entity line has no entity description.";
	(exists $attrs->{CardID}) || die "power log show entity line has no card id.";
	
	$parser_data->{"attributes"} = $attrs;
	}

sub _parse_power_log_tag_change($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# tag change actions have an attribute list with entity, tag and value.
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	(exists $attrs->{Entity}) || die "power log tag change does not have a target entity.";
	(exists $attrs->{tag}) || die "power log tag change does not have a tag name.";
	(exists $attrs->{value}) || die "power log tag change does not have a tag value.";
	
	$parser_data->{attributes} = $attrs;
	}
	
sub _parse_power_log_block_start($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# action groups have an attribute list with block type, owning entity, effect card id,
	# effect index and target id.
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	(exists $attrs->{BlockType}) || die "power log action block start has no type.";
	(exists $attrs->{Entity}) || die "power log action block start has no owning entity.";
	(exists $attrs->{EffectCardId}) || die "power log action block start has no effect card ID.";
	(exists $attrs->{EffectIndex}) || die "power log action block start has no effect index.";
	(exists $attrs->{Target}) || die "power log action block start has no target ID.";
	 
	$parser_data->{attributes} = $attrs;
	}
	
sub _parse_power_log_block_end($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# action end lines are blank.
	$parser_data->{attributes} = {};
	}

sub _parse_power_log_show_entity($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# show entity lines have a preamble "updating" before their attribute list.
	($line =~ s/^\s*-\s*Updating//) || die "power log show entity line has missing preamble.";
	
	# we're expecting an entity and a card id.
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	(exists $attrs->{Entity}) || die "power log show entity line has no entity description.";
	(exists $attrs->{CardID}) || die "power log show entity line has no card id.";
	
	$parser_data->{attributes} = $attrs;
	}
	
sub _parse_power_log_hide_entity($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# hide entity lines have a leading dash.
	($line =~ s/^\s*-//) || die "power log hide entity line missing expected leading dash.";
	
	# expecting entity, tag and value attributes
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	(exists $attrs->{Entity}) || die "power log hide entity line has no entity description.";
	(exists $attrs->{tag}) || die "power log hide entity line has no tag.";
	(exists $attrs->{value}) || die "power log hide entity line has no value.";
	
	$parser_data->{attributes} = $attrs;
	}
	
sub _parse_power_log_metadata($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# metadata lines lead with a dash before their attribute list
	($line =~ s/^\s*-//) || die "power log hide metadata missing expected leading dash.";
	
	# we're expecting meta, data and info attributes.
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	(exists $attrs->{Meta}) || die "power log metadata line has no meta type.";
	(exists $attrs->{Data}) || die "power log metadata line has no value.";
	(exists $attrs->{Info}) || die "power log metadata line has no additional info.";
	
	$parser_data->{attributes} = $attrs;
	}

our $_hs_power_log_action_parsers = {
	CREATE_GAME => \&_parse_power_log_create_game_action,
	GameEntity => \&_parse_power_log_game_entity,
	Player => \&_parse_power_log_player,
	FULL_ENTITY => \&_parse_power_log_full_entity,
	CHANGE_ENTITY => \&_parse_power_log_change_entity,
	TAG_CHANGE => \&_parse_power_log_tag_change,
	ACTION_START => \&_parse_power_log_block_start,
	ACTION_END => \&_parse_power_log_block_end,
	BLOCK_START => \&_parse_power_log_block_start,
	BLOCK_END => \&_parse_power_log_block_end,
	SHOW_ENTITY =>\&_parse_power_log_show_entity,
	HIDE_ENTITY => \&_parse_power_log_hide_entity,
	META_DATA => \&_parse_power_log_metadata
};

sub _parse_power_log_game_state($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# find an action for this line, if any.
	my $action = $self->_parse_power_log_line_action(\$line, $parser_data);
	
	# if this log line has an action, mark the previous action complete.
	unless ($action eq "")
		{
		$self->_parse_power_log_action_complete();
		$self->{log_metadata}->{current_action} = $action;
		
		# invoke the parser for this action
		(exists $_hs_power_log_action_parsers->{$action}) || die("unknown action found in power log.");
		$_hs_power_log_action_parsers->{$action}($self, $line, $parser_data);
		}
	else
		{
		# parse the attributes in this line
		my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
		$parser_data->{"attributes"} = $attrs;
		}
	
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	
	# decrement the list counter if required
	--$self->{log_metadata}->{current_list}
		if ($self->{log_metadata}->{current_list} > 0);
	}
	
sub _parse_power_log_entity_choices($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	
	unless ($self->{log_metadata}->{current_action} eq "EntityChoices")
		{
		$self->_parse_power_log_action_complete();
		$self->{log_metadata}->{current_action} = "EntityChoices";
		
		# the lead line of an entity choice group has an id, a player name, tasklist ID,
		# choice type, min and max option count.
		
		(exists $attrs->{id}) || die "power log choice group has no id.";
		(exists $attrs->{Player}) || die "power log choice group has no player name.";
		(exists $attrs->{TaskList}) || die "power log choice group has no tasklist id.";
		(exists $attrs->{ChoiceType}) || die "power log choice group has no choice type.";
		(exists $attrs->{CountMin}) || die "power log choice group has no miniumum selection count.";
		(exists $attrs->{CountMax}) || die "power log choice group has no maximum selection count.";
		}
	
	$parser_data->{attributes} = $attrs;
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}

sub _parse_power_log_send_choices($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	
	unless ($self->{log_metadata}->{current_action} eq "SendChoices")
		{
		$self->_parse_power_log_action_complete();
		$self->{log_metadata}->{current_action} = "SendChoices";
		
		# the lead line of a send choice group has a choice id and type.
		
		(exists $attrs->{id}) || die "power log send choice group has no choice id.";
		(exists $attrs->{ChoiceType}) || die "power log send choice group has no choice type.";
		}
		
	$parser_data->{attributes} = $attrs;
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}
	
sub _parse_power_log_debug_dump($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# debug dumps are always standalone lines, so complete the previous action
	$self->_parse_power_log_action_complete();
	$self->{log_metadata}->{current_action} = "DebugDump";
	
	# some debug dumps have an "action-like" preamble before their attribute list
	my $preamble = $self->_parse_power_log_line_action(\$line, $parser_data);
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	
	$parser_data->{preamble} = $preamble;
	$parser_data->{attributes} = $attrs;
	
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}

sub _parse_power_log_history_list($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# esentially irrelevant standalone lines, parsed simply for completeness,
	# these lines have an attribute.
	$self->_parse_power_log_action_complete();
	$self->{log_metadata}->{current_action} = "PrepareHistoryList";
	
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	$parser_data->{attributes} = $attrs;
	
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}

sub _parse_power_log_end_current_task_list($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# another standalone line type we don't particularly care about,
	# consists of a one element attribute list.
	$self->_parse_power_log_action_complete();
	$self->{log_metadata}->{current_action} = "EndCurrentTaskList";
	
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	$parser_data->{attributes} = $attrs;
	
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}
	
sub _parse_power_log_entites_chosen($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	
	unless ($self->{log_metadata}->{current_action} eq "EntitiesChosen")
		{
		$self->_parse_power_log_action_complete();
		$self->{log_metadata}->{current_action} = "EntitiesChosen";
		
		# the lead line of an entities chosen group has a choice id, player and entities count.
		
		(exists $attrs->{id}) || die "power log entities chosen group has no choice id.";
		(exists $attrs->{Player}) || die "power log entities chosen group has no player name.";
		(exists $attrs->{EntitiesCount}) || die "power log entities chosen group has no entities count.";
		}
		
	$parser_data->{attributes} = $attrs;
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}

sub _parse_power_log_print_options($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	my $attrs = {};
	
	unless ($self->{log_metadata}->{current_action} eq "PrintOptions")
		{
		$self->_parse_power_log_action_complete();
		$self->{log_metadata}->{current_action} = "PrintOptions";
		
		$attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
		
		# the lead line of a print options group has just an ID.
		(exists $attrs->{id}) || die "power log print options group has no id.";
		}
	else
		{
		# other lines in a print options group have a leading "option", "subOption" or "target" line
		($line =~ s/^\s*(target|(sub)?[Oo]ption)\s+(\d+)//) || die "power log print option group line has no target/option preamble.";
		
		$parser_data->{option_type} = $1;
		$parser_data->{option_index} = $3;
		
		$attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
		}
	
	$parser_data->{attributes} = $attrs;
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}
	
sub _parse_power_log_send_option($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# send option lines are standalone lines with a short attribute list.
	$self->_parse_power_log_action_complete();
	$self->{log_metadata}->{current_action} = "SendOption";
	
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	$parser_data->{attributes} = $attrs;
	
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}
	
sub _parse_power_log_wait_show_choices($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# another short, standalone line with an attribute list.
	$self->_parse_power_log_action_complete();
	$self->{log_metadata}->{current_action} = "WaitThenShowChoices";
	
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	$parser_data->{attributes} = $attrs;
	
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}
	
sub _parse_power_log_wait_hide_choices($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# the counterpart to show choices, exactly the same line type.
	$self->_parse_power_log_action_complete();
	$self->{log_metadata}->{current_action} = "WaitThenHideChoices";
	
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	$parser_data->{attributes} = $attrs;
	
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}
	
sub _parse_power_log_init_debug_message_line($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# there seem to be a number of pure debugging lines logging error messages that consist of
	# a debug message and an attribute list tagging the entity the refer to. We can parse them
	# all as one type.
	$self->_parse_power_log_action_complete();
	$self->{log_metadata}->{current_action} = "ErrorDebugMessage";
	
	# get the message text to the start of the attribute list
	($line =~ s/^\s+([^\[]+)//) || die "power log error debug message line has no debug message.";
	
	$parser_data->{message} = $1;
	my $attrs = $self->_parse_power_log_line_attributes($line, $parser_data);
	$parser_data->{attributes} = $attrs;
	
	push(@{$self->{log_metadata}->{current_lines}}, $parser_data);
	}

our $_hs_power_log_line_parsers = {
	GameState => {
		DebugPrintPowerList => \&_parse_power_log_list,
		DebugPrintPower => \&_parse_power_log_game_state,
		DebugPrintEntityChoices => \&_parse_power_log_entity_choices,
		SendChoices => \&_parse_power_log_send_choices,
		DebugPrintEntitiesChosen => \&_parse_power_log_entites_chosen,
		DebugPrintOptions => \&_parse_power_log_print_options,
		SendOption => \&_parse_power_log_send_option,
		ReportStuck => \&_parse_power_log_init_debug_message_line
	},
	PowerTaskList => {
		DebugDump => \&_parse_power_log_debug_dump,
		DebugPrintPower => \&_parse_power_log_game_state,
	},
	PowerProcessor => {
		PrepareHistoryForCurrentTaskList => \&_parse_power_log_history_list,
		EndCurrentTaskList => \&_parse_power_log_end_current_task_list,
		DoTaskListForCard => \&_parse_power_log_init_debug_message_line
	},
	ChoiceCardMgr => {
		WaitThenShowChoices => \&_parse_power_log_wait_show_choices,
		WaitThenHideChoices => \&_parse_power_log_wait_hide_choices
	},
	PowerSpellController => {
		InitPowerSpell => \&_parse_power_log_init_debug_message_line,
		InitPowerSounds => \&_parse_power_log_init_debug_message_line
	},
	SecretSpellController => {
		InitTriggerSpell => \&_parse_power_log_init_debug_message_line,
		InitTriggerSounds => \&_parse_power_log_init_debug_message_line
	},
	TriggerSpellController => {
		InitTriggerSpell => \&_parse_power_log_init_debug_message_line,
		InitTriggerSounds => \&_parse_power_log_init_debug_message_line
	}
};

sub _parse_power_log_line($$$)
	{
	my ($self, $line, $parser_data) = @_;
	
	# parse and chomp the log line type
	($line =~ _R_HS_POWERLOG_LINETYPE) || die("power log line has no intelligable type.");
	$line = substr($line, length($1));
	
	$parser_data->{category} = $2;
	$parser_data->{type} = $5;
	$parser_data->{attributes} = {};
	
	if (defined $4)
		{
		$parser_data->{category_task_list} = $4;
		}
	
	# find and call the handler for the line type
	(exists $_hs_power_log_line_parsers->{$2}) || die("power log line category has no handlers.");
	(exists $_hs_power_log_line_parsers->{$2}->{$5}) || die("power log line type has no handlers.");
	
	$_hs_power_log_line_parsers->{$2}->{$5}($self, $line, $parser_data);
	}

sub _parse_log_line($$)
	{
	my ($self, $line) = @_;
	
	my $parser_data = {};
	
	# parse and chomp the log entry timestamp
	($line =~ _R_HS_LOG_TIMESTAMP) || die("log line has no timestamp.");
	$line = substr($line, length($1));
	
	my $timestamp = {
		hour => $2,
		minute => $3,
		second => $4,
		usecond => $5
	};
	$parser_data->{timestamp} = $timestamp;
	
	# parse specific log line type
	
	if ($self->{log_type} == HS_LOG_TYPE_POWER)
		{
		$self->_parse_power_log_line($line, $parser_data);
		}
	else
		{
		die("log parser has invalid log type.");
		}
		
	return $parser_data;
	}

1;