# Do /TRIGGER HELP for help

use strict;
use Irssi 20020324 qw (command_bind command_runsub command signal_add_first signal_continue signal_stop signal_remove);
use Text::ParseWords;
use IO::File;
use Data::Dumper; 
use vars qw($VERSION %IRSSI);

$VERSION = '0.6.1+1';
%IRSSI = (
	authors  	=> 'Wouter Coekaerts',
	contact  	=> 'wouter@coekaerts.be',
	name    	=> 'trigger',
	description 	=> 'execute a command or replace text, triggered by a message,notice,join,part,quit,kick,topic or invite',
	license 	=> 'GPLv2',
	url     	=> 'http://wouter.coekaerts.be/irssi/',
	changed  	=> '$LastChangedDate$',
);

sub cmd_help {
	Irssi::print ( <<SCRIPTHELP_EOF

TRIGGER LIST
TRIGGER SAVE 
TRIGGER RELOAD
TRIGGER MOVE <number> <number>
TRIGGER DELETE <number>
TRIGGER CHANGE <number> <options like in add>
TRIGGER ADD %|[-<types>] [-pattern <pattern>|-regexp <regexp>] [-nocase] [-tags <tags>] [-channels <channels>] [-masks <masks>] [-hasmode <hasmode>] [-hasflag <hasflag>]
            [-command <command>] [-replace <replace>] [-once] [-stop]

When to match:
     -<types>: Trigger on these types of messages. The different types are:
                 publics,privmsgs,pubactions,privactions,pubnotices,privnotices,joins,parts,quits,kicks,topics,invites
                 -all is an alias for all of the above.
               Types that aren't included in -all:
                 rawin: raw text incoming from the server
                 send_text: lines you type that aren't commands
                 beep: when irssi beeps
     -pattern: The message must match <pattern>. ? and * can be used as wildcards
     -regexp: The message must match <regexp>. (see man perlre)
     -nocase: Match the regexp case insensitive
     -tags: Only trigger on server with tag in <tags>. A space-delimited list.
     -channels: Only trigger in <channels>. A space-delimited list. (use quotes)
                Examples: '#chan1 #chan2' or 'IRCNet/#channel'
                          -channels 'EFNet/' means every channel on EFNet and is the same as -tags 'EFNet'
     -masks: Only for messages from someone matching one of the <masks> (space seperated)
     -hasmode: Only if the person who triggers it has the <hasmode>
                Examples: '-o' means not opped, '+ov' means opped OR voiced, '-o&-v' means not opped AND not voiced
     -hasflag: Only works if friends.pl (friends_shasta.pl) or people.pl is loaded.
               Only trigger if the person who triggers it has <hasflag> in the script

What to do when it matches:
     -command: Execute <command>
                You are able to use \$1, \$2 and so on generated by your regexp pattern.
                For multiple command \$; can be used as seperator
                The following variables are also expanded:          
                   \$T: Server tag
                   \$C: Channel name
                   \$N: Nickname of the person who triggered this command
                   \$A: His address (foo\@bar.com),
                   \$I: His ident (foo)
                   \$H: His hostname (bar.com)
                   \$M: The complete message
                \$\\X, with X being one of the above expands (e.g. \$\\M), escapes all non-alphanumeric characters, so it can be used with /eval or /exec. Don't use /eval or /exec without this, it's not safe.

     -replace: replaces the matching part with <replace> in your irssi (requires a <regexp>)
     -once: remove the trigger if it is triggered, so it only executes once and then is forgotten.
     -stop: stops the signal. It won't get displayed by Irssi. Like /IGNORE
     
Examples:
 Knockout people who do a !list:
   /TRIGGER ADD -publics -channels "#channel1 #channel2" -nocase -regexp ^!list -command "KN \$N This is not a warez channel!"
 React to !echo commands from people who are +o in your friends-script:
   /TRIGGER ADD -publics -regexp '^!echo (.*)' -hasflag '+o' -command 'say echo: \$1'
 Ignore all non-ops on #channel:
   /TRIGGER ADD -publics -actions -channels "#channel" -hasmode '-o' -stop
 Send a mail to yourself every time a topic is changed:
   /TRIGGER ADD -topics -command 'exec echo \$\\N changed topic of \$\\C to: \$\\M | mail you\@somewhere.com -s topic'
 

Examples with -replace:
 Replace every occurence of shit with sh*t, case insensitive:
   /TRIGGER ADD -all -nocase -regexp shit -replace sh*t
 Strip all colorcodes from *!lamer\@*:
   /TRIGGER ADD -all -masks *!lamer\@* -regexp '\\x03\\d?\\d?(,\\d\\d?)?|\\x02|\\x1f|\\x16|\\x06' -replace ''
 Never let *!bot1\@foo.bar or *!bot2\@foo.bar hilight you
 (this works by cutting your nick in 2 different parts, 'myn' and 'ick' here)
 you don't need to understand the -replace argument, just trust that it works if the 2 parts separately don't hilight:
   /TRIGGER ADD -all masks '*!bot1\@foo.bar *!bot2\@foo.bar' -regexp '(myn)(ick)' -nocase -replace '\$1\\x02\\x02\$2'
 Avoid being hilighted by !top10 in eggdrops with stats.mod (but show your nick in bold):
   /TRIGGER ADD -publics -regexp '(Top.0\\(.*\\): 1.*)(my)(nick)' -replace '\$1\\x02\$2\\x02\\x02\$3\\x02'
 Convert a Windows-1252 Euro to an ISO-8859-15 Euro (same effect as euro.pl):
   /TRIGGER ADD -regexp '\\x80' -replace '\\xA4'
 Show tabs as spaces, not the inverted I (same effect as tab_stop.pl):
   /TRIGGER ADD -all -regexp '\\t' -replace '    '
SCRIPTHELP_EOF
   ,MSGLEVEL_CLIENTCRAP);
} # /

my @triggers; # array of all triggers
my %triggers_by_type; # hash mapping types on triggers of that type
my $recursion_depth = 0;

###############
### formats ###
###############

Irssi::theme_register([
	'trigger_header' => 'Triggers:',
	'trigger_line' => '%#$[-4]0 $1',
	'trigger_added' => 'Trigger $0 added: $1',
	'trigger_not_found' => 'Trigger {hilight $0} not found',
	'trigger_saved' => 'Triggers saved to $0',
	'trigger_loaded' => 'Triggers loaded from $0'
]);

#########################################
### catch the signals & do your thing ###
#########################################

my @signals = (
# "message public", SERVER_REC, char *msg, char *nick, char *address, char *target
{
	'types' => ['publics'],
	'signal' => 'message public',
	'sub' => sub {check_signal_message(\@_,1,$_[0],$_[4],$_[2],$_[3],'publics');}
},
# "message private", SERVER_REC, char *msg, char *nick, char *address
{
	'types' => ['privmsgs'],
	'signal' => 'message private',
	'sub' => sub {check_signal_message(\@_,1,$_[0],undef,$_[2],$_[3],'privmsgs');}
},
# "message irc action", SERVER_REC, char *msg, char *nick, char *address, char *target
{
	'types' => ['privactions','pubactions'],
	'signal' => 'message irc action',
	'sub' => sub {
		if ($_[4] eq $_[0]->{nick}) {
			check_signal_message(\@_,1,$_[0],undef,$_[2],$_[3],'privactions');
		} else {
			check_signal_message(\@_,1,$_[0],$_[4],$_[2],$_[3],'pubactions');
		}
	}
},
# "message irc notice", SERVER_REC, char *msg, char *nick, char *address, char *target
{
	'types' => ['privnotices','pubnotices'],
	'signal' => 'message irc notice',
	'sub' => sub {
		if ($_[4] eq $_[0]->{nick}) {
			check_signal_message(\@_,1,$_[0],undef,$_[2],$_[3],'privnotices');
		} else {
			check_signal_message(\@_,1,$_[0],$_[4],$_[2],$_[3],'pubnotices');
		}
	}
},
# "message join", SERVER_REC, char *channel, char *nick, char *address
{
	'types' => ['joins'],
	'signal' => 'message join',
	'sub' => sub {check_signal_message(\@_,-1,$_[0],$_[1],$_[2],$_[3],'joins');}
},
# "message part", SERVER_REC, char *channel, char *nick, char *address, char *reason
{
	'types' => ['parts'],
	'signal' => 'message part',
	'sub' => sub {check_signal_message(\@_,4,$_[0],$_[1],$_[2],$_[3],'parts');}
},
# "message quit", SERVER_REC, char *nick, char *address, char *reason
{
	'types' => ['quits'],
	'signal' => 'message quit',
	'sub' => sub {check_signal_message(\@_,3,$_[0],undef,$_[1],$_[2],'quits');}
},
# "message kick", SERVER_REC, char *channel, char *nick, char *kicker, char *address, char *reason
{
	'types' => ['kicks'],
	'signal' => 'message kick',
	'sub' => sub {check_signal_message(\@_,5,$_[0],$_[1],$_[3],$_[4],'kicks');}
},
# "message topic", SERVER_REC, char *channel, char *topic, char *nick, char *address
{
	'types' => ['topics'],
	'signal' => 'message topic',
	'sub' => sub {check_signal_message(\@_,2,$_[0],$_[1],$_[3],$_[4],'topics');}
},
# "message invite", SERVER_REC, char *channel, char *nick, char *address
{
	'types' => ['invites'],
	'signal' => 'message invite',
	'sub' => sub {check_signal_message(\@_,-1,$_[0],$_[1],$_[2],$_[3],'invites');}
},
# "server incoming", SERVER_REC, char *data
{
	'types' => ['rawin'],
	'signal' => 'server incoming',
	'sub' => sub {check_signal_message(\@_,1,$_[0],undef,undef,undef,'rawin');}
},
# "send command", char *args, SERVER_REC, WI_ITEM_REC
{
	'types' => ['send_command'],
	'signal' => 'send command',
	'sub' => sub {
		sig_send_text_or_command(\@_,1);
	}
},
# "send text", char *line, SERVER_REC, WI_ITEM_REC
{
	'types' => ['send_text'],
	'signal' => 'send text',
	'sub' => sub {
		sig_send_text_or_command(\@_,0);
	}
},
# "beep"
{
	'types' => ['beep'],
	'signal' => 'beep',
	'sub' => sub {check_signal_message(\@_,-1,undef,undef,undef,undef,'beep');}
},
# "event "<cmd>, SERVER_REC, char *args, char *sender_nick, char *sender_address
{
	'types' => ['mode_channel'],
	'signal' => 'event mode',
	'sub' => sub {
		my ($server, $args, $nickname, $address) = @_;
		my ($target, $modes, $modeargs) = split(/ /, $args, 3);
		return if (!$server->ischannel($target));
		my (@modeargs) = split(/ /,$modeargs);
		my ($pos, $type, $modearg) = (0, '+');
		foreach my $char (split(//,$modes)) {
			if ($char eq "+" || $char eq "-") {
				$type = $char;
			} elsif ($char =~ /[Oovh]/) { # mode_nick
				$pos++;
			} else {				
				if ($char =~ /[beIqdk]/ || ( $char =~ /[lfJ]/ && $type eq '+')) {
					$modearg = $modeargs[$pos++];
				} else {
					$modearg = undef;
				}
				check_signal_message(\@_,-1,$server,$target,$nickname,$address,'mode_channel',{ 'mode_type' => $type, 'mode_char' => $char, 'mode_arg' => $modearg});
			}
		}
	}
}
);

sub sig_send_text_or_command {
	my ($signal, $iscommand) = @_;
	my ($line, $server, $item) = @$signal;
	my ($channelname,$nickname,$address) = (undef,undef,undef);
	if ($item && (ref($item) eq 'Irssi::Irc::Channel' || ref($item) eq 'Irssi::Silc::Channel')) {
		$channelname = $item->{'name'};
	} elsif ($item && ref($item) eq 'Irssi::Irc::Query') { # TODO Silc query ?
		$nickname = $item->{'name'};
		$address = $item->{'address'}
	}
	# TODO pass context also for non-channels (queries and other stuff)
	check_signal_message($signal,0,$server,$channelname,$nickname,$address,$iscommand ? 'send_command' : 'send_text');

}

my %filters = (
'mode_type' => {
	'types' => ['mode_channel'],
	'sub' => sub {
		my ($param, $signal,$parammessage,$server,$channelname,$nickname,$address,$condition,$extra) = @_;
		return (($param) eq $extra->{'mode_type'});
	}
},
'mode_char' => {
	'types' => ['mode_channel'],
	'sub' => sub {
		my ($param, $signal,$parammessage,$server,$channelname,$nickname,$address,$condition,$extra) = @_;
		return (($param) eq $extra->{'mode_char'});
	}
}
);

# trigger types in -all option
my @trigger_all_switches = ('publics','privmsgs','pubactions','privactions','pubnotices','privnotices','joins','parts','quits','kicks','topics','invites');
# all trigger types
my @trigger_types = @trigger_all_switches;
push @trigger_types, 'rawin', 'send_command', 'send_text', 'beep', 'mode_channel';
# list of all switches
my @trigger_switches = @trigger_types;
push @trigger_switches, 'nocase', 'stop','once';
# parameters (with an argument)
my @trigger_params = ('masks','channels','tags','pattern','regexp','command','replace','hasmode','hasflag');
# list of all options (including switches)
my @trigger_options = ('all');
push @trigger_options, @trigger_switches;
push @trigger_options, @trigger_params;
push @trigger_options, keys(%filters); 

# check the triggers on $signal's $parammessage parameter, for triggers with $condition set
#  on $server in $channelname, for $nickname!$address
# set $parammessage to -1 if the signal doesn't have a message
# for signal without channel, nick or address, set to undef
sub check_signal_message {
	my ($signal,$parammessage,$server,$channelname,$nickname,$address,$condition,$extra) = @_;
	my ($trigger, $changed, $stopped, $context, $need_rebuild);
	my $message = ($parammessage == -1) ? '' : $signal->[$parammessage];

	return if (!$triggers_by_type{$condition});
	
	if ($recursion_depth > 10) {
		Irssi::print("Trigger error: Maximum recursion depth reached, aborting trigger.", MSGLEVEL_CLIENTERROR);
		return;
	}
	$recursion_depth++;

TRIGGER:	
	for (my $index=0;$index < scalar(@{$triggers_by_type{$condition}});$index++) { 
		my $trigger = $triggers_by_type{$condition}->[$index];
		if (!$trigger->{$condition}) {
			next; # wrong type of message
		}
		if ($trigger->{'tags'}) { # check if the tag matches
			if (!defined($server)) {
				next;
			}
			my $matches = 0;
			foreach my $tag (split(/ /,$trigger->{'tags'})) {
				if (lc($server->{'tag'}) eq lc($tag)) {
					$matches = 1;
					last;
				}
			}
			if (!$matches) {
				next;
			}
		}
	
		if ($trigger->{'channels'}) { # check if the channel matches
			if (!defined($channelname) || !defined($server)) {
				next;
			}
			my $matches = 0;
			foreach my $trigger_channel (split(/ /,$trigger->{'channels'})) {
				if (lc($channelname) eq lc($trigger_channel)
				  || lc($server->{'tag'}.'/'.$channelname) eq lc($trigger_channel)
				  || lc($server->{'tag'}.'/') eq lc($trigger_channel)) {
					$matches = 1;
					last; # this channel matches, stop checking channels
				}
			}
			if (!$matches) {
				next; # this trigger doesn't match, try next trigger...
			}
		}
		# check the mask
		if ($trigger->{'masks'} && (!defined($nickname) || !defined($address) || !defined($server) || !$server->masks_match($trigger->{'masks'}, $nickname, $address))) {
			next; # this trigger doesn't match

		}
		# check hasmodes
		if ($trigger->{'hasmode'}) {
			my ($channelrec, $nickrec);
			( defined($channelname)
			  and defined($nickname)
			  and defined($server)
			  and $channelrec = $server->channel_find($channelname)
			  and $nickrec = $channelrec->nick_find($nickname)
			) or next;

			my $modes = ($nickrec->{'op'}?'o':'').($nickrec->{'voice'}?'v':'').($nickrec->{'halfop'}?'h':'');
			if (!check_modes($modes,$trigger->{'hasmode'})) {
				next;
			}	
		}

		# check hasflags
		if ($trigger->{'hasflag'}) {
			if (!defined($nickname) || !defined($address) || !defined($server)) {
				next;
			}
			my $flags = get_flags ($server->{'chatnet'},$channelname,$nickname,$address);
			if (!defined($flags)) {
				next;
			}
			if (!check_modes($flags,$trigger->{'hasflag'})) {
				next;
			}
		}
		
		# check filters
		foreach my $trigfilter (@{$trigger->{'filters'}}) {
			print "DEBUG: checking filter " . $trigfilter->[0];
			# TODO save reference to filter directly into trigger... but then we can't use Dumper for saving
			if (! $filters{$trigfilter->[0]}->{'sub'}($trigfilter->[1], $signal,$parammessage,$server,$channelname,$nickname,$address,$condition,$extra) ) {
				next TRIGGER;
			}
		}
		
		# check regexp (and keep matches in @- and @+, so don't make a this a {block})
		next if ($trigger->{'compregexp'} && ($parammessage == -1 || $message !~ m/$trigger->{'compregexp'}/));
		
		# if we got this far, it fully matched, and we need to do the replace/command/stop/once
		my $expands = {
			'M' => $message,
			'T' => (defined($server)) ? $server->{'tag'} : '',
			'C' => $channelname,
			'N' => $nickname,
			'A' => $address,
			'I' => ((!defined($address)) ? '' : substr($address,0,index($address,'@'))),
			'H' => ((!defined($address)) ? '' : substr($address,index($address,'@')+1)),
			'$' => '$',
			';' => ";"
		};

		if (defined($trigger->{'replace'})) { # it's a -replace
			$message =~ s/$trigger->{'compregexp'}/do_expands($trigger->{'compreplace'},$expands,$message)/ge;
			$changed = 1;
		}
		
		if ($trigger->{'command'}) { # it's a (nonempty) -command
			my $command = $trigger->{'command'};
			# $1 = the stuff behind the $ we want to expand: a number, or a character from %expands
			$command = do_expands($command, $expands, $message);
			
			if (defined($server)) {
				if (defined($channelname) && $server->channel_find($channelname)) {
					$context = $server->channel_find($channelname);
				} else {
					$context = $server;
				}
			} else {
				$context = undef;
			}
			
			if (defined($context)) {
				$context->command("eval $command");
			} else {
				Irssi::command("eval $command");
			}
		}
		
		if ($trigger->{'stop'}) {
			$stopped = 1;
		}
		
		if ($trigger->{'once'}) {
			# find this trigger in the real trigger list, and remove it
			for (my $realindex=0;$realindex < scalar(@triggers);$realindex++) {
				if ($triggers[$realindex] == $trigger) {
					splice (@triggers,$realindex,1);
					last;
				}
			}
			$need_rebuild = 1;
		}
	}

	if ($need_rebuild) {
		rebuild();
	}
	if ($stopped) { # stopped with -stop
		signal_stop();
	} elsif ($changed) { # changed with -replace
		$signal->[$parammessage] = $message;
		signal_continue(@$signal);
	}
	$recursion_depth--;
}

# used in check_signal_message to expand $'s
# $inthis is a string that can contain $ stuff (like 'foo$1bar$N')
sub do_expands {
	my ($inthis, $expands, $from) = @_;
	# @+ and @- are copied because there are two s/// nested, and the inner needs the $1 and $2,... of the outer one
	my @plus = @+;
	my @min = @-;
	my $p = \@plus; my $m = \@min;
	$inthis =~ s/\$(\\*(\d+|[^0-9x]|x[0-9a-fA-F][0-9a-fA-F]))/expand_and_escape($1,$expands,$m,$p,$from)/ge;	
	return $inthis;
}

# \ $ and ; need extra escaping because we use eval
sub expand_and_escape {
	my $retval = expand(@_);
	$retval =~ s/([\\\$;])/\\\1/g;
	return $retval;
}

# used in do_expands (via expand_and_escape), to_expand is the part after the $
sub expand {
	my ($to_expand,$expands,$min,$plus,$from) = @_;
	if ($to_expand =~ /^\d+$/) { # a number => look up in $vars
		# from man perlvar:
		# $3 is the same as "substr $var, $-[3], $+[3] - $-[3])"
		return ($to_expand > @{$min} ? '' : substr($from,$min->[$to_expand],$plus->[$to_expand]-$min->[$to_expand]));
	} elsif ($to_expand =~ s/^\\//) { # begins with \, so strip that from to_expand
		my $exp = expand($to_expand,$expands,$min,$plus,$from); # first expand without \
		$exp =~ s/([^a-zA-Z0-9])/\\\1/g; # escape non-word chars
		return $exp;
	} elsif ($to_expand =~ /x([0-9a-fA-F]{2})/) { # $xAA
		return chr(hex($1));
	} else { # look up in $expands
		return $expands->{$to_expand};
	}
}

sub check_modes {
	my ($has_modes, $need_modes) = @_;
	my $matches;
	my $switch = 1; # if a '-' if found, will be 0 (meaning the modes should not be set)
	foreach my $need_mode (split /&/,$need_modes) {
		$matches = 0;
		foreach my $char (split //,$need_mode) {
			if ($char eq '-') {
				$switch = 0;
			} elsif ($char eq '+') {
				$switch = 1;
			} elsif ((index($has_modes,$char) != -1) == $switch) {
				$matches = 1;
				last;
			}
		}
		if (!$matches) {
			return 0;
		}
	}
	return 1;
}

# get someones flags from people.pl or friends(_shasta).pl
sub get_flags {
	my ($chatnet, $channel, $nick, $address) = @_;
	my $flags;
	no strict 'refs';
	if (defined %{ 'Irssi::Script::people::' }) {
		if (defined ($channel)) {
			$flags = (&{ 'Irssi::Script::people::find_local_flags' }($chatnet,$channel,$nick,$address));
		} else {
			$flags = (&{ 'Irssi::Script::people::find_global_flags' }($chatnet,$nick,$address));
		}
		$flags = join('',keys(%{$flags}));
	} else {
		my $shasta;
		if (defined %{ 'Irssi::Script::friends_shasta::' }) {
			$shasta = 'friends_shasta';
		} elsif (defined &{ 'Irssi::Script::friends::get_idx' }) {
			$shasta = 'friends';
		}
		if (!$shasta) {
			return undef;
		}
		my $idx = (&{ 'Irssi::Script::'.$shasta.'::get_idx' }($nick,$address));
		if ($idx == -1) {
			return '';
		}
		$flags = (&{ 'Irssi::Script::'.$shasta.'::get_friends_flags' }($idx,undef));
		if ($channel) {
			$flags .= (&{ 'Irssi::Script::'.$shasta.'::get_friends_flags' }($idx,$channel));
		}
	}
	return $flags;
}

########################################################
### internal stuff called by manage, needed by above ###
########################################################

my %mask_to_regexp = ();
foreach my $i (0..255) {
    my $ch = chr $i;
    $mask_to_regexp{$ch} = "\Q$ch\E";
}
$mask_to_regexp{'?'} = '(.)';
$mask_to_regexp{'*'} = '(.*)';

sub compile_trigger {
	my ($trigger) = @_;
	my $regexp;
	
	if ($trigger->{'regexp'}) {
		$regexp = $trigger->{'regexp'};
	} elsif ($trigger->{'pattern'}) {
		$regexp = $trigger->{'pattern'};
		$regexp =~ s/(.)/$mask_to_regexp{$1}/g;
	} else {
		delete $trigger->{'compregexp'};
		return;
	}
	
	if ($trigger->{'nocase'}) {
		$regexp = '(?i)' . $regexp;
	}
	
	$trigger->{'compregexp'} = qr/$regexp/;
	
	if(defined($trigger->{'replace'})) {
		(my $replace = $trigger->{'replace'}) =~ s/\$/\$\$/g;
		$trigger->{'compreplace'} = Irssi::parse_special($replace);
	}
}

# rebuilds triggers_by_type and updates signal binds
sub rebuild {
	%triggers_by_type = ();
	foreach my $trigger (@triggers) {
		foreach my $type (@trigger_types) {
			if ($trigger->{$type}) {
				push @{$triggers_by_type{$type}}, ($trigger);
			}
		}
	}
	
	foreach my $signal (@signals) {
		my $should_bind = 0;
		foreach my $type (@{$signal->{'types'}}) {
			if (defined($triggers_by_type{$type})) {
				$should_bind = 1;
			}
		}
		if ($should_bind && !$signal->{'bind'}) {
			signal_add_first($signal->{'signal'}, $signal->{'sub'});
			$signal->{'bind'} = 1;
		} elsif (!$should_bind && $signal->{'bind'}) {
			signal_remove($signal->{'signal'}, $signal->{'sub'});
			$signal->{'bind'} = 0;
		}
	}
}

################################
### manage the triggers-list ###
################################

# TRIGGER SAVE
sub cmd_save {
	my $filename = Irssi::settings_get_str('trigger_file');
	my $io = new IO::File $filename, "w";
	if (defined $io) {
		my $dumper = Data::Dumper->new([\@triggers]);
		$dumper->Purity(1)->Deepcopy(1);
		$io->print("#Triggers file version $VERSION\n");
		$io->print($dumper->Dump);
		$io->close;
	}
	#Irssi::print("Triggers saved to ".$filename);
	Irssi::printformat(MSGLEVEL_CLIENTNOTICE, 'trigger_saved', $filename);
}

# save on unload
sub sig_command_script_unload {
	my $script = shift;
	if ($script =~ /(.*\/)?$IRSSI{'name'}(\.pl)? *$/) {
		cmd_save();
	}
}

# TRIGGER LOAD
sub cmd_load {
	my $converted = 0;
	my $filename = Irssi::settings_get_str('trigger_file');
	my $io = new IO::File $filename, "r";
	if (not defined $io) {
		if (-e $filename) {
			Irssi::print("Error opening triggers file", MSGLEVEL_CLIENTERROR);
		}
		return;
	}
	if (defined $io) {
		no strict 'vars';
		my $text;
		$text .= $_ foreach ($io->getlines);
		my $file_version = '';
		if ($text =~ /^#Triggers file version (.*)\n/) {
			$file_version = $1;
		}
		my $rep = eval "$text";
		@triggers = @$rep if ref $rep;
		
		for (my $index=0;$index < scalar(@triggers);$index++) { 
			my $trigger = $triggers[$index];

			# compile regexp
			compile_trigger($trigger);

			if ($file_version lt '0.6.1') {
				# convert old names: notices => pubnotices, actions => pubactions
				foreach $oldname ('notices','actions') {
					if ($trigger->{$oldname}) {
						delete $trigger->{$oldname};
						$trigger->{'pub'.$oldname} = 1;
						$converted = 1;
					}
				}
			}
			if ($file_version lt '0.6.1+1' && $trigger->{'modifiers'}) {
				if ($trigger->{'modifiers'} =~ /i/) {
					$trigger->{'nocase'} = 1;
					Irssi::print("Trigger: trigger ".($index+1)." had 'i' in it's modifiers, it has been converted to -nocase");
				}
				if ($trigger->{'modifiers'} !~ /^[ig]*$/) {
					Irssi::print("Trigger: trigger ".($index+1)." had unrecognised modifier '". $trigger->{'modifiers'} ."', which couldn't be converted.");
				}
				delete $trigger->{'modifiers'};
				$converted = 1;
			}
			
			if (defined($trigger->{'replace'}) && ! $trigger->{'regexp'}) {
				Irssi::print("Trigger: trigger ".($index+1)." had -replace but no -regexp, removed it");
				splice (@triggers,$index,1);
				$index--; # nr of next trigger now is the same as this one was
			}
		}
	}
	#Irssi::print("Triggers loaded from ".$filename);
	Irssi::printformat(MSGLEVEL_CLIENTNOTICE, 'trigger_loaded', $filename);
	if ($converted) {
		Irssi::print("Trigger: Triggers file will be in new format next time it's saved.");
	}
	rebuild();
}

# converts a trigger back to "-switch -options 'foo'" form
sub to_string {
	my ($trigger) = @_;
	my $string;
	
	# check if all @trigger_all_switches are set
	my $all_set = 1;
	foreach my $switch (@trigger_all_switches) {
		if (!$trigger->{$switch}) {
			$all_set = 0;
			last;
		}
	}
	if ($all_set) {
		$string .= '-all ';	
	} else {
		foreach my $switch (@trigger_switches) {
			if ($trigger->{$switch}) {
				$string .= '-'.$switch.' ';
			}
		}
	}
	
	foreach my $trigfilter (@{$trigger->{'filters'}}) {
		$string .= '-' . $trigfilter->[0] . " '$trigfilter->[1]' ";
	}

	foreach my $param (@trigger_params) {
		if ($trigger->{$param} || ($param eq 'replace' && defined($trigger->{'replace'}))) {
			$string .= '-' . $param . " '$trigger->{$param}'".' ';
		}
	}
	return $string;
}

# find a trigger (for REPLACE and DELETE), returns index of trigger, or -1 if not found
sub find_trigger {
	my ($data) = @_;
	if ($data =~ /^[0-9]*$/ and defined($triggers[$data-1])) {
		return $data-1;
	}
	#for (my $i=0;$i<scalar(@triggers);$i++) {
	#	if ($triggers[$i]->{'regexp'} eq $data) {
	#		return $i;
	#	}
	#}
	#Irssi::print ("Trigger $data not found.");
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'trigger_not_found', $data);
	return -1; # not found
}


# TRIGGER ADD <options>
sub cmd_add {
	my ($data, $server, $item) = @_;
	my @args = &shellwords($data . ' a');
	
	my $trigger = parse_options({},@args);
	if ($trigger) {
		push @triggers, $trigger;
		#Irssi::print("Added trigger " . scalar(@triggers) .": ". to_string($trigger));
		Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'trigger_added', scalar(@triggers), to_string($trigger));
	}
	rebuild();
}

# TRIGGER CHANGE <nr> <options>
sub cmd_change {
	my ($data, $server, $item) = @_;
	my @args = &shellwords($data . ' a');
	my $index = find_trigger(shift @args);
	if ($index != -1) {
		if(parse_options($triggers[$index],@args)) {
			Irssi::print("Trigger " . ($index+1) ." changed to: ". to_string($triggers[$index]));
		}
	}
	rebuild();
}

# parses options for TRIGGER ADD and TRIGGER CHANGE
# if invalid args returns undef, else changes $thetrigger and returns it
sub parse_options {
	my ($thetrigger,@args) = @_;
	my ($trigger, $option);
	
	if (pop(@args) ne 'a') {
		Irssi::print("Syntax error, probably missing a closing quote", MSGLEVEL_CLIENTERROR);
		return undef;
	}
	
	%$trigger = %$thetrigger; # make a copy to prevent changing the given trigger if args doesn't parse
ARGS:	for (my $arg = shift @args; $arg; $arg = shift @args) {
		# expand abbreviated options, put in $option
		$arg =~ s/^-//;
		$option = undef;
		foreach my $ioption (@trigger_options) {
			if (index($ioption, $arg) == 0) { # -$opt starts with $arg
				if ($option) { # another already matched
					Irssi::print("Ambiguous option: $arg", MSGLEVEL_CLIENTERROR);
					return undef;
				}
				$option = $ioption;
				last if ($arg eq $ioption); # exact match is unambiguous
			}
		}
		if (!$option) {
			Irssi::print("Unknown option: $arg", MSGLEVEL_CLIENTERROR);
			return undef;
		}

		# -<param> <value>
		foreach my $param (@trigger_params) {
			if ($option eq $param) {
				$trigger->{$param} = shift @args;
				next ARGS;
			}
		}
		# -all
		if ($option eq 'all') {
			foreach my $switch (@trigger_all_switches) {
				$trigger->{$switch} = 1;
			}
			next ARGS;
		}

		# -[no]<switch>
		foreach my $switch (@trigger_switches) {
			# -<switch>
			if ($option eq $switch) {
				$trigger->{$switch} = 1;
				next ARGS;
			}
			# -no<switch>
			elsif ($option eq 'no'.$switch) {
				$trigger->{$switch} = undef;
				next ARGS;
			}
		}
		
		if ($filters{$option}) {
			push @{$trigger->{'filters'}}, [$option, shift @args];
			next ARGS;
		}
	}
	
	if (defined($trigger->{'replace'}) && ! $trigger->{'regexp'} && !$trigger->{'pattern'}) {
		Irssi::print("Trigger error: Can't have -replace without -regexp", MSGLEVEL_CLIENTERROR);
		return undef;
	}

	if ($trigger->{'pattern'} && $trigger->{'regexp'}) {
		Irssi::print("Trigger error: Can't have -pattern and -regexp in same trigger", MSGLEVEL_CLIENTERROR);
		return undef;
	}

	# check if it has at least one type
	my $has_a_type;
	foreach my $type (@trigger_types) {
		if ($trigger->{$type}) {
			$has_a_type = 1;
			last;
		}
	}
	if (!$has_a_type) {
		Irssi::print("Warning: this trigger doesn't trigger on any type of message. you probably want to add -publics or -all");
	}
	
	compile_trigger($trigger);
	%$thetrigger = %$trigger; # copy changes to real trigger
	return $thetrigger;
}

# TRIGGER DELETE <num>
sub cmd_del {
	my ($data, $server, $item) = @_;
	my @args = &shellwords($data);
	my $index = find_trigger(shift @args);
	if ($index != -1) {
		Irssi::print("Deleted ". ($index+1) .": ". to_string($triggers[$index]));
		splice (@triggers,$index,1);
	}
	rebuild();
}

# TRIGGER MOVE <num> <num>
sub cmd_move {
	my ($data, $server, $item) = @_;
	my @args = &shellwords($data);
	my $index = find_trigger(shift @args);
	if ($index != -1) {
		my $newindex = shift @args;
		if ($newindex < 1 || $newindex > scalar(@triggers)) {
			Irssi::print("$newindex is not a valid trigger number");
			return;
		}
		Irssi::print("Moved from ". ($index+1) ." to $newindex: ". to_string($triggers[$index]));
		$newindex -= 1; # array starts counting from 0
		my $trigger = splice (@triggers,$index,1); # remove from old place
		splice (@triggers,$newindex,0,($trigger)); # insert at new place
	}
}

# TRIGGER LIST
sub cmd_list {
	#my (@args) = @_;
	#Irssi::print ("Trigger list:",MSGLEVEL_CLIENTCRAP);
	Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'trigger_header');
	my $i=1;
	foreach my $trigger (@triggers) {
		#Irssi::print(" ". $i++ .": ". to_string($trigger),MSGLEVEL_CLIENTCRAP);
		Irssi::printformat(MSGLEVEL_CLIENTCRAP, 'trigger_line', $i++, to_string($trigger));
	}
}

######################
### initialisation ###
######################

command_bind('trigger help',\&cmd_help);
command_bind('help trigger',\&cmd_help);
command_bind('trigger add',\&cmd_add);
command_bind('trigger change',\&cmd_change);
command_bind('trigger move',\&cmd_move);
command_bind('trigger list',\&cmd_list);
command_bind('trigger delete',\&cmd_del);
command_bind('trigger save',\&cmd_save);
command_bind('trigger reload',\&cmd_load);
command_bind 'trigger' => sub {
    my ( $data, $server, $item ) = @_;
    $data =~ s/\s+$//g;
    command_runsub ( 'trigger', $data, $server, $item ) ;
};
signal_add_first 'default command trigger' => sub {
	# gets triggered if called with unknown subcommand
	cmd_help();
};

Irssi::signal_add_first('command script load', 'sig_command_script_unload');
Irssi::signal_add_first('command script unload', 'sig_command_script_unload');
Irssi::signal_add('setup saved', 'cmd_save');

# This makes tab completion work
Irssi::command_set_options('trigger add',join(' ',@trigger_options));
Irssi::command_set_options('trigger change',join(' ',@trigger_options));

Irssi::settings_add_str($IRSSI{'name'}, 'trigger_file', Irssi::get_irssi_dir()."/triggers");

cmd_load();
