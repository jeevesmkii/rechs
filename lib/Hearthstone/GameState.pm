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

package Hearthstone::GameState;

use strict;
use warnings;
use Hearthstone::LogParser;

use Data::Dumper;

# Hearthstone game event types
use constant {
	HS_GAME_EVENT_NEW_GAME => 1,
	HS_GAME_EVENT_GAME_ABANDONED => 2,
	HS_GAME_EVENT_GAME_ENTITY_CREATED => 3,
	HS_GAME_EVENT_TURN_STARTED => 4,
	HS_GAME_EVENT_CARD_PLAYED => 5,
	HS_GAME_EVENT_WEAPON_DESTROYED => 6,
	HS_GAME_EVENT_HERO_DESTROYED => 7,
	HS_GAME_EVENT_HERO_POWER_DESTROYED => 8,
	HS_GAME_EVENT_WEAPON_EQUIPPED => 9,
	HS_GAME_EVENT_ENTITY_CHANGED => 10,
	HS_GAME_EVENT_ENTITY_CONTROLLER_CHANGED => 11,
	HS_GAME_EVENT_HERO_ENTITY_CHANGED => 12,
	HS_GAME_EVENT_HERO_POWER_ENTITY_CHANGED => 13,
	HS_GAME_EVENT_HERO_POWER_USED => 14,
	HS_GAME_EVENT_ENTITY_ATTACKING => 15,
	HS_GAME_EVENT_ENTITY_DEFENDING => 16,
	HS_GAME_EVENT_CHOICE => 17,
	HS_GAME_EVENT_TARGETTING => 18,
	HS_GAME_EVENT_JOUST => 19,
	HS_GAME_EVENT_HEALING => 20,
	HS_GAME_SECRET_TRIGGERED => 21,
	HS_GAME_EVENT_PLAYER_CONCEDED => 22,
	HS_GAME_EVENT_PLAYER_LOST => 23,
	HS_GAME_EVENT_PLAYER_WON => 24,
	HS_GAME_EVENT_GAME_COMPLETE => 25
};

sub new($$$)
	{
	my ($pkg, $base_path, $event_callback, $error_callback) = @_;
	
	my $self = bless { 
		game_events => [],
		
		on_event => $event_callback,
		on_error => $error_callback
	};
	
	my $log_action_handler = sub
		{
		my ($action) = @_;
		$self->_update_game_state($action);
		};
	
	my $log_error_handler = sub
		{
		my ($error) = @_;
		# TODO: error handling
		};
	
	$self->{power_log} = Hearthstone::LogParser->new($base_path, Hearthstone::LogParser::HS_LOG_TYPE_POWER,
		$log_action_handler, $log_error_handler);
	
	return $self;
	}
	
sub get_last_action($)
	{
	my ($self) = @_;
	
	return $self->{last_action}; 
	}
	
sub get_entity($$)
	{
	my ($self, $entity_id) = @_;
	
	my $entity = undef;
	if (exists $self->{current_game})
		{
		$entity = $self->_lookup_entity($entity_id);
		}
	return $entity;
	}
	
sub get_game_state($)
	{
	my ($self) = @_;
	my $game_state = {};
	
	if (exists $self->{current_game})
		{
		$game_state = {
			game_entity_id => $self->{current_game}->{game_entity_id},
			players => $self->{current_game}->{players},
			current_player => $self->{current_game}->{current_player},
			last_card_played => $self->{current_game}->{last_card_played}
			};
		}
		
	return $game_state;
	}
	
# Private methods

# common entity tags
use constant {
	_HS_ENTITY_TAG_PLAYER => "CONTROLLER",
	_HS_ENTITY_TAG_PLAY_ZONE => "ZONE",
	_HS_ENTITY_TAG_ZONE_POS => "ZONE_POSITION",
	_HS_ENTITY_TAG_ENTITY_TYPE => "CARDTYPE"
};

sub _queue_game_event($$$@)
	{
	my ($self, $event_type, $metadata_ref, @entities_list) = @_;
	
	my $event = {
		event_type => $event_type,
		event_entities => \@entities_list,
		event_metadata => $metadata_ref
	};

	push(@{$self->{game_events}}, $event);
	}
	
sub _dispatch_events($)
	{
	my ($self) = @_;
	while (my $event = shift @{$self->{game_events}})
		{
		$self->{on_event}($event);
		}
	}
	
sub _lookup_entity($$)
	{
	my ($self, $entity_id) = @_;
	
	my $entity = undef;
	if (ref($entity_id))
		{
		# use the entity_id field in the full entity description to look up our entity
		(exists $entity_id->{id}) || die "hearthstone game state action contains full entity description that is missing an entity ID.";
		$entity_id = $entity_id->{id};
		}
	
	# if this is not a numeric entity ID, attempt to resolve the reference
	unless ($entity_id =~ /^\d+$/)
		{
		if ($entity_id eq "GameEntity")
			{
			# the string "GameEntity" can be used as a reference to the game board
			$entity_id = $self->{current_game}->{game_entity_id};
			}
		else
			{
			# otherwise, this is a player name. Tediously, player names are not explicitly attached
			# to a player before being used. It used to be the rule that the first player was always mentioned last,
			# but now that convention seems to have changed with the recent patch. Sigh. Hopefully, this will always be right.
			
			my $unknown_player = undef;
			foreach my $player_id (1, 2)
				{
				if (exists $self->{current_game}->{players}->{$player_id})
					{
					my $player_entity_id = $self->{current_game}->{players}->{$player_id};
					my $player_entity = $self->{current_game}->{entities}->{$player_entity_id};
					
					if ($player_entity->{entity_name} eq "")
						{
						# this player has yet to be assigned a name, so give it this one.
						$player_entity->{entity_name} = $entity_id;
						$entity_id = $player_entity_id;
						last;
						}
					elsif ($player_entity->{entity_name} eq $entity_id)
						{
						# this entity name matches the name assigned to this player, use this entity.
						$entity_id = $player_entity_id;
						last;
						}
					
					$unknown_player = $player_entity
						if ($player_entity->{entity_name} eq "UNKNOWN HUMAN PLAYER");
					}
				}
			
			if (!($entity_id =~ /^\d+$/))
				{
				# occasionally, hearthstone will identify an opponent as "unknown human player" until it queries their actual name.
				# if that's the case here, set the actual name of the player
				if ($unknown_player)
					{
					$unknown_player->{entity_name} = $entity_id;
					$entity_id = $unknown_player->{entity_id};
					}
				else
					{
			 	 	die "heartstone game state action contains an unknown entity alias.";
			 	 	}
			 	 }
			}
		}
	
	die "hearthstone game state failed to locate entity specified in action."
		unless exists $self->{current_game}->{entities}->{$entity_id};
			
	return $self->{current_game}->{entities}->{$entity_id};
	}

sub _handle_tag_update($$$$)
	{
	my ($self, $entity, $tag, $old_value) = @_;
	
	if ($old_value ne $entity->{tags}->{$tag})
		{
		if ($entity->{entity_id} == $self->{current_game}->{game_entity_id} &&
				$tag eq "NEXT_STEP" && $entity->{tags}->{$tag} eq "MAIN_START_TRIGGERS")
			{
			# A new turn has begun, check which player is currently playing
			my $current_player = $self->_lookup_entity($self->{current_game}->{players}->{1});
			$current_player = $self->_lookup_entity($self->{current_game}->{players}->{2})
				unless (exists $current_player->{tags}->{CURRENT_PLAYER} && $current_player->{tags}->{CURRENT_PLAYER} eq "1");
			
			# if the current player has changed, notify the client
			if ($self->{current_game}->{current_player} != $current_player->{player_id})
				{
				$self->{current_game}->{current_player} = $current_player->{player_id};
				$self->_queue_game_event(HS_GAME_EVENT_TURN_STARTED, undef, $current_player->{entity_id});
				}
			}
		elsif ($tag eq "JUST_PLAYED" && $entity->{tags}->{$tag} eq "1")
			{
			# if a card has just been played, notify the client
			$self->{current_game}->{last_card_played} = $entity->{entity_id};
			$self->_queue_game_event(HS_GAME_EVENT_CARD_PLAYED, undef, $entity->{entity_id});
			}
		elsif ($tag eq "ZONE")
			{
			# if the entity's zone has changed, we may need to update the game state
			my $owner = $self->_lookup_entity($self->{current_game}->{players}->{$entity->{tags}->{CONTROLLER}});
			$entity->{play_zone} = $entity->{tags}->{$tag};
			
			if ($old_value eq "HAND")
				{
				$self->_remove_from_zone($owner->{hand}, $entity);
				}
			elsif ($old_value eq "SECRET")
				{
				$self->_remove_from_zone($owner->{secrets}, $entity);
				}
			elsif ($old_value eq "PLAY")
				{
				if ($entity->{entity_type} eq "WEAPON")
					{
					# if the entity moving is a weapon, reset the weapon slot
					$owner->{weapon} = -1
						if ($owner->{weapon} == $entity->{entity_id});
					$self->_queue_game_event(HS_GAME_EVENT_CARD_PLAYED, undef, $entity->{entity_id});
					}
				elsif ($entity->{entity_type} eq "HERO")
					{
					$owner->{hero} = -1
						if ($owner->{hero} == $entity->{entity_id});
					$self->_queue_game_event(HS_GAME_EVENT_CARD_PLAYED, undef, $entity->{entity_id});
					}
				elsif ($entity->{entity_type} eq "HERO_POWER")
					{
					# if we've destroyed a hero power, remove it from the hero
					$owner->{hero_power} = -1
						if ($owner->{hero_power} == $entity->{entity_id});
					$self->_queue_game_event(HS_GAME_EVENT_HERO_POWER_DESTROYED, undef, $entity->{entity_id});
					}
				else
					{
					$self->_remove_from_zone($owner->{board}, $entity);
					}
				}
				
			if ($entity->{tags}->{$tag} eq "HAND")
				{
				push(@{$owner->{hand}}, $entity->{entity_id});
				$self->_adjust_zone_position($owner->{hand}, $entity);
				}
			elsif ($entity->{tags}->{$tag} eq "SECRET")
				{
				push(@{$owner->{secrets}}, $entity->{entity_id});
				}
			elsif ($entity->{tags}->{$tag} eq "PLAY")
				{
				if ($entity->{entity_type} eq "WEAPON")
					{
					# if the entity entering play is a weapon, add it to the weapon slot
					$owner->{weapon} = $entity->{entity_id};
					$self->_queue_game_event(HS_GAME_EVENT_WEAPON_EQUIPPED, undef, $entity->{entity_id});
					}
				elsif ($entity->{entity_type} eq "HERO_POWER")
					{
					# if its a hero power, the hero power slot
					$owner->{hero_power} = $entity->{entity_id};
					$self->_queue_game_event(HS_GAME_EVENT_HERO_POWER_ENTITY_CHANGED, undef, $entity->{entity_id});
					}	
				else
					{
					push(@{$owner->{board}}, $entity->{entity_id});
					$self->_adjust_zone_position($owner->{board}, $entity);
					}
				}
			}
		elsif ($tag eq "CONTROLLER")
			{
			my $prev_controller =  $self->_lookup_entity($self->{current_game}->{players}->{$old_value});
			my $new_controller =  $self->_lookup_entity($self->{current_game}->{players}->{$entity->{tags}->{$tag}});
			
			# Currently only secrets and minions may change owners, this may change in future.
			if ($entity->{play_zone} eq "SECRET")
				{
				$self->_remove_from_zone($prev_controller->{secrets}, $entity);
				push(@{$new_controller->{secrets}}, $entity->{entitiy_id});
				}
			else
				{
				$self->_remove_from_zone($prev_controller->{board}, $entity);
				push(@{$new_controller->{board}}, $entity->{entity_id});
				$self->_adjust_zone_position($new_controller->{board}, $entity);
				}
				
			$self->_queue_game_event(HS_GAME_EVENT_ENTITY_CONTROLLER_CHANGED, undef, $entity->{entity_id});
			}
		elsif ($tag eq "PROPOSED_DEFENDER")
			{
			my $defender = $entity->{tags}->{$tag};
			if ($defender)
				{
				my $defending_entity = $self->_lookup_entity($entity->{tags}->{$tag});
				$self->_queue_game_event(HS_GAME_EVENT_ENTITY_CONTROLLER_CHANGED, undef, $entity->{entity_id});
				}
			}
		elsif ($tag eq "PLAYSTATE")
			{
			my $play_state = $entity->{tags}->{$tag};
			if ($play_state eq "CONCEDED")
				{
				$self->_queue_game_event(HS_GAME_EVENT_PLAYER_CONCEDED, undef, $entity->{entity_id});
				}
			elsif ($play_state eq "LOST")
				{
				$self->_queue_game_event(HS_GAME_EVENT_PLAYER_LOST, undef, $entity->{entity_id});
				}
			elsif ($play_state eq "WON")
				{
				$self->_queue_game_event(HS_GAME_EVENT_PLAYER_WON, undef, $entity->{entity_id});
				}
			}
		elsif ($tag eq "STATE")
			{
			my $game_state = $entity->{tags}->{$tag};
			if ($game_state eq "COMPLETE")
				{
				# The game is over! Destroy the current game object
				$self->_queue_game_event(HS_GAME_EVENT_GAME_COMPLETE, undef, $entity->{entity_id});
				$self->_dispatch_events();
				delete $self->{current_game};
				}
			}
		}
	
	if ($tag eq "ZONE_POSITION")
		{
		# if the card is in play or in the hand, adjust its position
		my $owner = $self->_lookup_entity($self->{current_game}->{players}->{$entity->{tags}->{CONTROLLER}});
		
		my $zone = undef;
		if ($entity->{play_zone} eq "HAND")
			{
			$zone = $owner->{hand};
			}
		elsif ($entity->{play_zone} eq "PLAY" && $entity->{entity_type} ne "WEAPON")
			{
			$zone = $owner->{board};
			}
			
		if (defined $zone)
			{
			$entity->{zone_pos} = $entity->{tags}->{$tag};
			$self->_adjust_zone_position($zone, $entity);
			}
		}
	}
	
sub _adjust_zone_position($$$)
	{
	my ($self, $zone_ptr, $entity) = @_;
	
	# if no zone position is specified, don't do the adjustment
	return if ($entity->{zone_pos} eq "");
	
	# find the entity's current position in the zone
	my $current_pos = -1;
	for (my $i = 0; $i < scalar(@{$zone_ptr}); $i++)
		{
		if (@{$zone_ptr}[$i] == $entity->{entity_id})
			{
			$current_pos = $i;
			last;
			}
		}
	($current_pos != -1) || die "hearthstone game state entity changed zone position while not in given zone.";
	
	# if this is a spell in the zero slot, move it to the end.
	if ($entity->{zone_pos} == 0)
		{
		splice(@{$zone_ptr}, $current_pos, 1);
		push(@{$zone_ptr}, $entity->{entity_id});
		return;
		}
	
	# find an appropriate position to insert this item.
	# if the requested zone position is beyond the end of the array, ignore this for now
	# and add it to the nearest to correct position. Errors will be caught in post-block sanity checks.
	my $position = scalar(@{$zone_ptr});
	for (my $i = 0; $i < scalar(@{$zone_ptr}); $i++)
		{
		my $other_entity = $self->_lookup_entity(@{$zone_ptr}[$i]);
		
		if ($other_entity->{entity_id} != $entity->{entity_id} && 
				($other_entity->{zone_pos} eq "" || $other_entity->{zone_pos} == 0 || 
				 $other_entity->{zone_pos} >= $entity->{zone_pos}))
			{
			$position = $i;
			last;
			}
		}
	
	$position--
		if ($position > $current_pos);
	
	if ($current_pos != $position)
		{
		# remove the entity from its current position and insert it in to its new home
		splice(@{$zone_ptr}, $current_pos, 1);
		if ($position > scalar(@{$zone_ptr}))
			{
			push(@{$zone_ptr}, $entity->{entity_id});
			}
		else
			{
			splice(@{$zone_ptr}, $position, 0, $entity->{entity_id});
			}
		}
	}
	
sub _remove_from_zone($$$)
	{
	my ($self, $zone_ptr, $entity) = @_;
	
	# find the entity's current position in the zone
	my $current_pos = -1;
	for (my $i = 0; $i < scalar(@{$zone_ptr}); $i++)
		{
		if (@{$zone_ptr}[$i] == $entity->{entity_id})
			{
			$current_pos = $i;
			last;
			}
		}
	($current_pos != -1) || die "hearthstone game state entity removed from zone while not in given zone.";
	
	# remove it.
	splice(@{$zone_ptr}, $current_pos, 1);
	}
	
sub _sanity_check_zone($$$)
	{
	my ($self, $zone_ptr, $zone_name) = @_;
	
	# iterate over every entity in the zone, check they're in the right place/position
	my $current_pos = 1;
	foreach my $entity_id (@{$zone_ptr})
		{
		my $entity = $self->_lookup_entity($entity_id);
		
		($entity->{play_zone} eq $zone_name) || die "hearthstone game state zone stanity check failed, entity in wrong zone.";
		if ($entity->{zone_pos} ne "" && $entity->{zone_pos} != 0)
			{
			($current_pos == $entity->{zone_pos}) || die "hearthstone game state zone sanity check failed, entity ($entity->{entity_id}) in wrong zone position.";
			}
		
		$current_pos++;
		}
	}

sub _create_new_game($$)
	{
	my ($self, $action) = @_;
	
	# if there's a game still notionally in progress when we get a new game event,
	# add a game abandoned event to the event log
	$self->_queue_game_event(HS_GAME_EVENT_GAME_ABANDONED, undef, $self->{current_game}->{game_entity_id})
		if (defined $self->{current_game});
		
	my $game_state =
		{
		game_entity_id => -1,
		players => {},
		current_player => -1,
		last_card_played => -1,
		entities => {},
		zones =>
			{
			play => {},
			graveyard => {}
			},
			
		flags => { 
			ignore_block => 0,
			block_depth => 0
			}
		};
	
	$self->{current_game} = $game_state;
	$self->_queue_game_event(HS_GAME_EVENT_NEW_GAME, undef);
	}
	
sub _create_game_entity($$)
	{
	my ($self, $action) = @_;
	
	(exists $self->{current_game}) || die "hearthstone game state recieved an entity creation action without a game in progress.";
	(exists $action->{entity_id}) || die "hearthstone game state recieved an entity creation action with no entity id."; 
	(exists $action->{tags}) || die "hearthstone game state recieved an entity creation action with no tags.";
	
	my $entity_id = $action->{entity_id};
	die "hearthstone game state recieved an entity creation action for an entity that already exists."
		if (exists $self->{current_game}->{entities}->{$entity_id});
		
	my $entity = {
		entity_id => $entity_id,
		tags => $action->{tags},
		
		entity_card_id => "",
		player_id => -1,
		entity_type => "",
		entity_name => "",
		play_zone => "",
		zone_pos => "",
		
		flags => {}
	};
	
	# where possible, extract the optional details from the entity description
	$entity->{entity_card_id} = $action->{entity_card_id}
		if (exists $action->{entity_card_id});
	$entity->{player_id} = $action->{player_id}
		if (exists $action->{player_id});
	$entity->{entity_name} = $action->{entity_name}
		if (exists $action->{entity_name});
	$entity->{play_zone} = $action->{play_zone}
		if (exists $action->{play_zone});
	$entity->{zone_pos} = $action->{zone_pos}
		if (exists $action->{zone_pos});
		
	# we can also fill in some details from tags where they exist
	$entity->{player_id} = $action->{tags}->{&_HS_ENTITY_TAG_PLAYER}
		if (exists $action->{tags}->{&_HS_ENTITY_TAG_PLAYER});
	$entity->{play_zone} = $action->{tags}->{&_HS_ENTITY_TAG_PLAY_ZONE}
		if (exists $action->{tags}->{&_HS_ENTITY_TAG_PLAY_ZONE});
	$entity->{zone_pos} = $action->{tags}->{&_HS_ENTITY_TAG_ZONE_POS}
		if (exists $action->{tags}->{&_HS_ENTITY_TAG_ZONE_POS});
	$entity->{entity_type} = $action->{tags}->{&_HS_ENTITY_TAG_ENTITY_TYPE}
		if (exists $action->{tags}->{&_HS_ENTITY_TAG_ENTITY_TYPE});
	
	# at a very minimum, all new entities must have a play zone.
	die "hearthstone game state recieved an entity creation action with no intelligable play zone."
		if ($entity->{play_zone} eq "");
	
	# unless this is a game creation action, we should also have a player id
	if ($action->{entity_type} != Hearthstone::LogParser::HS_POWER_LOG_ENTITY_GAME)
		{
		die "hearthstone game state recieved an entity creation action with player ID."
			if ($entity->{player_id} == -1);
		}
	
	$self->{current_game}->{entities}->{$entity_id} = $entity;
	
	if ($action->{entity_type} == Hearthstone::LogParser::HS_POWER_LOG_ENTITY_GAME)
		{
		die "heartstone game state recieved a game entity creation action when the game already exists."
			unless ($self->{current_game}->{game_entity_id} == -1);
			
		$self->{current_game}->{game_entity_id} = $entity_id;
		$self->_queue_game_event(HS_GAME_EVENT_GAME_ENTITY_CREATED, undef, $entity_id);
		}
	elsif ($action->{entity_type} == Hearthstone::LogParser::HS_POWER_LOG_ENTITY_PLAYER)
		{
		die "hearthstone game state recieved a player entity creation action when the player already exists"
			if (exists $self->{current_game}->{players}->{$entity->{player_id}});
		
		$self->{current_game}->{players}->{$entity->{player_id}} = $entity_id;
		
		# player entities have a hand list
		my @hand = ();
		$entity->{hand} = \@hand;
		
		# a board list
		my @board = ();
		$entity->{board} = \@board;
		
		# and a secrets list
		my @secrets = ();
		$entity->{secrets} = \@secrets;
		
		# as well as a hero entity, hero power and weapon
		$entity->{hero} = -1;
		$entity->{hero_power} = -1;
		$entity->{weapon} = -1;
		}
	# if we're creating hero or hero power type entities, attach them to the requisite player
	elsif (exists $entity->{tags}->{CARDTYPE} && $entity->{tags}->{CARDTYPE} eq "HERO")
		{
		my $player_entity = $self->_lookup_entity($self->{current_game}->{players}->{$entity->{tags}->{CONTROLLER}});
		$player_entity->{hero} = $entity->{entity_id};
		
		$self->_queue_game_event(HS_GAME_EVENT_HERO_ENTITY_CHANGED, undef, $entity->{entity_id});
		}
	elsif (exists $entity->{tags}->{CARDTYPE} && $entity->{tags}->{CARDTYPE} eq "HERO_POWER")
		{
		my $player_entity = $self->_lookup_entity($self->{current_game}->{players}->{$entity->{tags}->{CONTROLLER}});
		$player_entity->{hero_power} = $entity->{entity_id};
		
		$self->_queue_game_event(HS_GAME_EVENT_HERO_POWER_ENTITY_CHANGED, undef, $entity->{entity_id});
		}
	else
		{
		# some other entity types are created already in hand or in play, add them to appropriate zones
		if ($entity->{play_zone} eq "HAND")
			{
			# find the controller's hand and add this entity
			my $player = $self->_lookup_entity($self->{current_game}->{players}->{$entity->{tags}->{CONTROLLER}});
			push(@{$player->{hand}}, $entity->{entity_id});
			$self->_adjust_zone_position($player->{hand}, $entity);
			}
		elsif ($entity->{play_zone} eq "PLAY")
			{
			# ditto with the controller's board
			my $player = $self->_lookup_entity($self->{current_game}->{players}->{$entity->{tags}->{CONTROLLER}});
			
			if ($entity->{entity_type} eq "WEAPON")
				{
				$player->{weapon} = $entity->{entity_id};
				}
			else
				{
				push(@{$player->{board}}, $entity->{entity_id});
				$self->_adjust_zone_position($player->{board}, $entity);
				}
			}
		}
	}

sub _change_entity_tag($$)
	{
	my ($self, $action) = @_;
	
	# ignore tag changes that happen in irrelevant blocks.
	return
		if ($self->{current_game}->{flags}->{ignore_block});
	
	(exists $action->{entity}) || die "hearthstone game state recieved a tag update action with no entity ID.";
	(exists $action->{tag}) || die "hearthstone game state recieved a tag update action with no tag name.";
	(exists $action->{value}) || die "hearthstone game state recieved a tag update action with no tag value.";
	
	my $entity = $self->_lookup_entity($action->{entity});
	my $old_value = "";
	
	# sometimes tag updates are the first time a full entity will be described, so we can update from
	# the entity description.
	
	if (ref($action->{entity}))
		{
		if ($entity->{entity_name} eq "")
			{
			$entity->{entity_name} = $action->{entity}->{name}
				if (exists $action->{entity}->{name} && $action->{entity}->{name} ne "");
			}
			
		if ($entity->{entity_card_id} eq "")
			{
			$entity->{entity_card_id} = $action->{entity}->{cardId}
				if (exists $action->{entity}->{cardId} && $action->{entity}->{cardId} ne "");
			}
		
		if ($entity->{entity_type} eq "" || $entity->{entity_type} eq "INVALID")
			{
			$entity->{entity_type} = $action->{entity}->{type}
				if (exists $action->{entity}->{type} && $action->{entity}->{type} ne "");
			}
		}
	
	# store the old value, if any, for reference
	$old_value = $entity->{tags}->{$action->{tag}} 
		if (exists $entity->{tags}->{$action->{tag}});

	# update the specified tag
	$entity->{tags}->{$action->{tag}} = $action->{value};
	
	$self->_handle_tag_update($entity, $action->{tag}, $old_value);
	}
	
sub _notify_power_usage($$)
	{
	my ($self, $action) = @_;
	
	# Heartstone likes to reiterate plays in power task list blocks that already happened in game state
	# blocks. Ignore these.
	
	$self->{current_game}->{flags}->{ignore_block}++
		if ($action->{block_category} eq "PowerTaskList");
	$self->{current_game}->{flags}->{block_depth}++;
	
	if (!$self->{current_game}->{flags}->{ignore_block})
		{
		if ($action->{block_type} eq "PLAY")
			{
			my $played_entity = $self->_lookup_entity($action->{entity});
		
			$self->_queue_game_event(HS_GAME_EVENT_HERO_POWER_USED, undef, $played_entity->{entity_id})
				if ($played_entity->{entity_type} eq "HERO_POWER");
			}
		elsif ($action->{block_type} eq "ATTACK")
			{
			my $attacking_entity = $self->_lookup_entity($action->{entity});
			$self->_queue_game_event(HS_GAME_EVENT_ENTITY_ATTACKING, undef, $attacking_entity->{entity_id});
			}
		elsif ($action->{block_type} eq "TRIGGER")
			{
			# notify for secrets triggering
			my $triggered_entity = $self->_lookup_entity($action->{entity});
			$self->_queue_game_event(HS_GAME_SECRET_TRIGGERED, undef, $triggered_entity->{entity_id})
				if ($triggered_entity->{play_zone} eq "SECRET");
			}
		}
	}
	
sub _sanity_check_game_state($)
	{
	my ($self) = @_;
	
	$self->{current_game}->{flags}->{block_depth}--;
	$self->{current_game}->{flags}->{ignore_block}--
		if ($self->{current_game}->{flags}->{ignore_block});
	
	($self->{current_game}->{flags}->{block_depth} >= 0) || die "heartstone game state block nesting error.";
	
	# Sanity check only on top level blocks
	if ($self->{current_game}->{flags}->{block_depth} == 0)
		{
		my $player = $self->_lookup_entity($self->{current_game}->{players}->{1});
		$self->_sanity_check_zone($player->{hand}, "HAND");
		$self->_sanity_check_zone($player->{board}, "PLAY");
		
		$player = $self->_lookup_entity($self->{current_game}->{players}->{2});
		$self->_sanity_check_zone($player->{hand}, "HAND");
		$self->_sanity_check_zone($player->{board}, "PLAY");
		
		$self->_dispatch_events();
		}
	}
	
sub _present_entity_choices($$)
	{
	my ($self, $action) = @_;
	
	return
		if ($self->{current_game}->{flags}->{ignore_block});
	
	my $player_entity = $self->_lookup_entity($action->{player});
	
	if ($action->{choice_type} eq "MULLIGAN")
		{
		# From the mulligan, we can tell which player is the local player.
		my $mulligan_entity = $self->_lookup_entity(@{$action->{entity_choices}}[0]->{entity_id});
		$player_entity->{is_local} = ($mulligan_entity->{entity_card_id} ne "");
		}
	
	if ($player_entity->{is_local})
		{
		my $event_metadata = {
			choice_type => $action->{choice_type},
			choice_count_max => $action->{choice_count_max}
			};
		
		my @entities = map { $_->{entity_id}; } @{$action->{entity_choices}};
		$self->_queue_game_event(HS_GAME_EVENT_CHOICE, $event_metadata, @entities);
		}
	}

sub _update_game_entity($$)
	{
	my ($self, $action) = @_;
	
	# ignore tag changes that happen in irrelevant blocks.
	return
		if ($self->{current_game}->{flags}->{ignore_block});
	
	(exists $action->{entity_id}) || die "hearthstone game state recieved an entity update action with no entity ID.";
	my $entity = $self->_lookup_entity($action->{entity_id});
	
	# update the entity description from the action header where available.
	if ($entity->{entity_name} eq "")
		{
		$entity->{entity_name} = $action->{entity}->{name}
			if (exists $action->{entity}->{name} && $action->{entity}->{name} ne "");
		}
		
	if ($entity->{entity_card_id} eq "")
		{
		$entity->{entity_card_id} = $action->{entity}->{cardId}
			if (exists $action->{entity}->{cardId} && $action->{entity}->{cardId} ne "");
			
		$entity->{entity_card_id} = $action->{entity_card_id}
			if (exists $action->{entity_card_id} && $action->{entity_card_id} ne "");
		}
		
	if ($entity->{entity_type} eq "" || $entity->{entity_type} eq "INVALID")
		{
		$entity->{entity_type} = $action->{entity}->{type}
			if (exists $action->{entity}->{type} && $action->{entity}->{type} ne "");
		}

	# some entity description fields can also be gleaned from tags if available
	$entity->{player_id} = $action->{tags}->{&_HS_ENTITY_TAG_PLAYER}
		if (exists $action->{tags}->{&_HS_ENTITY_TAG_PLAYER});
	$entity->{entity_type} = $action->{tags}->{&_HS_ENTITY_TAG_ENTITY_TYPE}
		if (exists $action->{tags}->{&_HS_ENTITY_TAG_ENTITY_TYPE});
	
	# iterate through all the tags to be updated
	foreach my $tag (keys(%{$action->{tags}}))
		{
		my $old_value = "";
		$old_value = $entity->{tags}->{$tag}
			if (exists $entity->{tags}->{$tag});
		$entity->{tags}->{$tag} = $action->{tags}->{$tag};
		
		$self->_handle_tag_update($entity, $tag, $old_value);
		}
	}

sub _notify_send_choices($$)
	{
	my ($self, $action) = @_;
	
	# TODO: send events for these actions.
	# they're mostly useless for our purposes, but could be used for sanity checks
	}
	
sub _change_entity($$)
	{
	my ($self, $action) = @_;
	
	return
		if ($self->{current_game}->{flags}->{ignore_block});
	
	my $entity = $self->_lookup_entity($action->{entity_id});
	
	# Send an event informing the client this entity has changed.
	# TODO: This event is currently exclusive to Shifter Zerus, and we're never told the new
	# name of the card until it is played, so clients would have to have hardcoding specific
	# to retrieving the actual name of the card. Consider if we should use the card database to
	# fetch the name in this case?
	my $old_card_id = $entity->{entity_card_id};
	$entity->{entity_card_id} = $action->{entity_card_id};
	
	my $event_metadata = { old_card_id => $old_card_id };
	$self->_queue_game_event(HS_GAME_EVENT_ENTITY_CHANGED, $event_metadata, $entity->{entity_id});
	
	$self->_update_game_entity($action);
	}

sub _notify_entities_chosen($$)
	{
	my ($self, $action) = @_;
	
	# TODO: send events for entities chosen
	}
	
sub _notify_show_entity($$)
	{
	my ($self, $action) = @_;
	
	# TODO: notify if this is an enemy card
	
	# update card details from this action
	$self->_update_game_entity($action);
	}
	
sub _notify_hide_entity($$)
	{
	my ($self, $action) = @_;
	
	# TODO: notify that we can no longer see the entity maybe?
	}

sub _notify_client_options($$)
	{
	my ($self, $action) = @_;
	
	# TODO: while I doubt I'll ever make use of these, it is probably worth notifying so I can build sanity checks
	}

sub _notify_send_option($$)
	{
	my ($self, $action) = @_;
	
	# TODO: again, if we send events for this I can build sanity checks to make sure our state is congruent with the actions
	# we do.
	}
	
sub _handle_log_metadata($$)
	{
	my ($self, $action) = @_;
	my @entity_info = @{$action->{entity_info}};
	
	# ignore power task list metadata items
	return
		if ($self->{current_game}->{flags}->{ignore_block});
	
	if ($action->{meta} eq "TARGET")
		{
		# For targetted powers, spells and battle cries, notify the client of the target
		my @entities = map { $_->{entity_id} } @entity_info;
		$self->_queue_game_event(HS_GAME_EVENT_TARGETTING, undef, @entities);
		}
	elsif ($action->{meta} eq "JOUST")
		{
		my $joust_winner = $self->_lookup_entity($action->{data});
		my $winning_player = $self->_lookup_entity($self->{current_game}->{players}->{$joust_winner->{player_id}});

		my $home_jouster = $self->_lookup_entity($entity_info[0]->{entity_id});
		my $away_jouster = $self->_lookup_entity($entity_info[1]->{entity_id});
		
		my $event_metadata = { joust_winner => $joust_winner->{entity_id} };
		$self->_queue_game_event(HS_GAME_EVENT_JOUST, $event_metadata, $home_jouster->{entity_id}, $away_jouster->{entity_id});
		}
	elsif ($action->{meta} eq "HEALING")
		{
		# Notify the client of healing targets
		my $target_entity = $self->_lookup_entity($entity_info[0]->{entity_id});
		my @entities = map { $_->{entity_id} } @entity_info;
		$self->_queue_game_event(HS_GAME_EVENT_HEALING, undef, @entities);
		}
	}

sub _update_game_state($$)
	{
	my ($self, $action) = @_;
	
	$self->{last_action} = $action;
	
	if ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_NEW_GAME)
		{
		$self->_create_new_game($action);
		}
	elsif (exists $self->{current_game})
		{
		# ignore gamestate changes until a new game starts
		
		if ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_CREATE_ENTITY)
			{
			$self->_create_game_entity($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_TAG_CHANGE)
			{
			$self->_change_entity_tag($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_BLOCK_START)
			{
			$self->_notify_power_usage($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_BLOCK_END)
			{
			# when action blocks end, do sanity checks on the current game state
			$self->_sanity_check_game_state();
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_ENTITY_CHOICES)
			{
			$self->_present_entity_choices($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_UPDATE_ENTITY)
			{
			$self->_update_game_entity($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_PREPARE_HISTORY_LIST ||
				$action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_END_TASK_LIST)
			{
			# ignore these. doesn't affect the game state.
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_SEND_CHOICES)
			{
			$self->_notify_send_choices($action)
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_ENTITIES_CHOSEN)
			{
			$self->_notify_entities_chosen($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_CHANGE_ENTITY)
			{
			$self->_change_entity($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_SHOW_ENTITY)
			{
			$self->_notify_show_entity($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_HIDE_ENTITY)
			{
			$self->_notify_hide_entity($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_PRINT_OPTIONS)
			{
			$self->_notify_client_options($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_SEND_OPTION)
			{
			$self->_notify_send_option($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_METADATA)
			{
			$self->_handle_log_metadata($action);
			}
		elsif ($action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_WAIT_SHOW_OPTIONS ||
				$action->{action_type} == Hearthstone::LogParser::HS_POWER_LOG_WAIT_HIDE_OPTIONS)
			{
			# We can probably ignore these, they seem reasonably irrelevant to game state.
			}
		else
			{
			die "hearthstone game state encountered unknown power log action type.";
			}
		}
	}

1;
