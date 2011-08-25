# Gmusicbrowser: Copyright (C) 2005-2011 Quentin Sculo <squentin@free.fr>
# laiteplay: Copyright (C) 2011- Markus Klinga <laite@gmx.com>
#
# This file is part of laiteplay, an individual fork of Gmusicbrowser.
# laiteplay is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3, as
# published by the Free Software Foundation.


# the plugin file must have the following block before the first non-comment line,
# it must be of the format :
# =gmbplugin PID
# name	short name
# title	long name, the short name is used if empty
# desc	description, may be multiple lines
# =cut
=gmbplugin ALBUMRANDOM
name	Albumrandom
title	AlbumRandom plugin (v.2)
desc	Albumrandom plays albums according to set weighted random.
=cut

# the plugin package must be named GMB::Plugin::PID (replace PID), and must have these sub :
# Start	: called when the plugin is activated
# Stop	: called when the plugin is de-activated
# prefbox : returns a Gtk2::Widget used to describe the plugin and set its options

#TODO

package GMB::Plugin::ALBUMRANDOM;
use strict;
use warnings;

use constant
{	OPT	=> 'PLUGIN_ALBUMRANDOM_',
};

use Gtk2::Notify -init, ::PROGRAM_NAME;

::SetDefaultOptions(OPT, writestats => 1, infinite => 1, shownotifications => 0, recalculate_time => 12, recalculate => 1
, requireallinfilter => 0, topalbumsonly => 1, topalbumamount => 50, multipleamount => 3, rememberplaymode => 1, neveraskwhenplaymodechanged => 0
, playmodechangedanswer => 'recalculate');

my $ON=0;

my %arb2=
(	class	=> 'Layout::Button',
	state	=> sub {$ON==1? 'albumrandom_on' : 'albumrandom_off'},
	stock	=> {albumrandom_on => 'plugin-albumrandom-on', albumrandom_off => 'plugin-albumrandom' },
	tip	=> " Albumrandom v.2 \n LClick - generate new random album \n MClick - Re-update Database \n RClick - Toggle Infinite Mode ON/OFF",	
	click1	=> sub {GenerateRandomAlbum(1);},
	click2	=> \&RecalculateButton,
	click3 => \&ToggleInfinite,
	autoadd_type	=> 'button main',
	event	=> 'AlbumrandomOn',
);

use base 'Gtk2::Box';
use base 'Gtk2::Dialog';
use utf8;


my $Logfile = $::HomeDir.'albumrandom.log';
my $Cachefile = $::HomeDir.'albumrandom.cache';
my $Log=Gtk2::ListStore->new('Glib::String');

my $notify=undef;
my ($Daemon_name,$can_actions,$can_body);

my $handle;
my $IDs = ();
my $logContent = '';
my $lastSong = -1;
my $originalMode=-1;
my $originalModeText = '';
my $logHasChanged = 0;

my $selected=-1;
my $oldSelected = -1;
my $oldID = -1;
my $lastDBUpdate = 0;


sub Start
{
	my $self=shift;

	Log("*** Initializing Albumrandom ***");

	Layout::RegisterWidget(Albumrandom=>\%arb2);
	
	$handle={};	#the handle to the Watch function must be a hash ref, if it is a Gtk2::Widget, UnWatch will be called when the widget is destroyed
	::Watch($handle, PlayingSong	=> \&Changed, Save	=> \&WriteStats);
}
sub Stop
{
	$ON=0;
	::HasChanged('AlbumrandomOn');
	$notify=undef;
	Layout::RegisterWidget('Albumrandom');
	::UnWatch($handle,'PlayingSong');
	::UnWatch($handle,'Save');
}

sub prefbox
{
	my $vbox= Gtk2::VBox->new(::FALSE, 2);

	my $check=::NewPrefCheckButton(OPT."writestats",'Write statistics',horizontal=>1);
	my $check2=::NewPrefCheckButton(OPT."infinite",'Infinite mode',horizontal=>1);
	my $check3=::NewPrefCheckButton(OPT."shownotifications",'Show notifications',horizontal=>1);
	my $check4=::NewPrefCheckButton(OPT."requireallinfilter",'Require all tracks of album in filter',horizontal=>1);	
	my $check5=::NewPrefCheckButton(OPT."rememberplaymode",'Remember & restore original playmode after Albumrandom finishes',horizontal=>1);
	
	my $button=Gtk2::Button->new();
	$button->signal_connect(clicked => sub {GenerateRandomAlbum(1);});
	$button->set_label("Generate (and enqueue) random album now");

	my $button2=Gtk2::Button->new();
	$button2->signal_connect(clicked => sub { GenerateRandomAlbum($::Options{OPT.'multipleamount'})});
	$button2->set_label("Generate multiple albums now");
	
	my $time_spin=::NewPrefSpinButton(OPT."recalculate_time", 1,168, step=>1, page=>4, wrap=>0);
	my $time_entry=::Hpack($time_spin,Gtk2::Label->new(' hours'));
	my $checkn=::NewPrefCheckButton(OPT."recalculate",'Re-calculate DB after ', widget=>$time_entry,horizontal=>1);
	
	my $top_nb=::NewPrefSpinButton(OPT."topalbumamount", 2,5000, step=>1,text1=>_" ", text2=>_" albums");
	my $topcheck=::NewPrefCheckButton(OPT."topalbumsonly",'Select only from top ', , widget=>$top_nb, horizontal=>1);

	my @list2 = ::GetListOfSavedLists();
	my $listcombo= ::NewPrefCombo( OPT.'multiplelist', \@list2);
	
	my @p;
	for my $mode (sort keys %{$::Options{SavedWRandoms}}) { push @p, $mode;}
	push @p, 'shuffle';
	my $pmcombo= ::NewPrefCombo( OPT.'randommode', \@p);
	my $pmlabel=Gtk2::Label->new('For weighting use playmode: ');
	
	@p = ();
	for my $mode (sort keys %{$::Options{SavedSorts}}) { push @p, $mode;}
	my $pmcombo2= ::NewPrefCombo( OPT.'straightmode', \@p);
	my $pmlabel2=Gtk2::Label->new('For playing albums use playmode: ');

	
	my $album_spin=::NewPrefSpinButton(OPT."multipleamount", 1,1000, step=>1, page=>4, wrap=>0);
	my $albumlabel1=Gtk2::Label->new('Multiple random: Generate ');
	my $albumlabel2=Gtk2::Label->new(' albums to ');

	my $listcombo2= ::NewPrefCombo( OPT.'playmodechangedanswer', { recalculate => 'Re-calculate DB', useold => 'Use the old DB',});
	my $nevercheck=::NewPrefCheckButton(OPT."neveraskwhenplaymodechanged",'Don\'t ask me what to do when playmode is different than calculated, just ',widget => $listcombo2,horizontal=>1);
	
	my $tweakcheck=::NewPrefCheckButton(OPT."tweakmode",'Tweak albumrandom',horizontal=>1);
	my $powerlabel=Gtk2::Label->new('Power: ');
	my $power=::NewPrefSpinButton(OPT."tweak_power", 1,5, step=>1, wrap=>0);
	my $multiplelabel=Gtk2::Label->new('Multiple (*100): ');
	my $multiple=::NewPrefSpinButton(OPT."tweak_multiple", 1,1000, step=>10, wrap=>0);
	
	my $fi = ::Vpack([$check,$check2],[$check3,$check4],$check5,$topcheck,$checkn,$nevercheck,
	[$pmlabel,$pmcombo],[$pmlabel2,$pmcombo2],[$albumlabel1,$album_spin,$albumlabel2,$listcombo],[$button,$button2],[$tweakcheck,$powerlabel,$power,$multiplelabel,$multiple]);

	$fi->add(::LogView($Log));
	
	return $fi;

}
sub Changed
{
	return Log("Tried to change with same ID twice!") if ($oldID == $::SongID);
	
	$oldID = $::SongID;
	
	#this has to be here, because it might get called even after plugin has shut down (e.g. when infinite mode is OFF, and album is played through)
	if ($oldSelected != -1)
	{
		UpdateAlbumFromID($oldSelected);
		$oldSelected = -1;
		Log("Reset old selection");
	}

	return if ($selected == -1);#no other business here, if haven't selected an album	

	my $al = AA::GetIDs('album',$IDs->[0][$selected]);
	my $isInAlbum=0;
	foreach my $track (@$al) { if ($::SongID == $track) {$isInAlbum = 1;}}

	#our album might still be in the queue, so rule that option out before declaring manual mode...
	if (($isInAlbum == 0) and (scalar@$::Queue == 0))
	{ 
		$ON = 0; 
		::HasChanged('AlbumrandomOn'); 
		Log("*** Manual change noted ***");
		Log("Trying to update last good album...");
		if ($selected != -1){ UpdateAlbumFromID($selected);}
		elsif ($oldSelected != -1){ UpdateAlbumFromID($oldSelected);}
		else { Log("Couldn't update - no suitable albumID left.");}
		$selected = -1; #set selected to -1, since we're not playing anything anymore
		Log("Trying to revert original playmode...");
		RestorePlaymode();
		return;
	}
	
	if ($::SongID == $lastSong)
	{
		Log("Last song playing, setting oldSelected");
		$oldSelected = $selected;
		
		if ($::Options{OPT.'infinite'} == 1){ Log("Infinite Mode: Generating next album"); GenerateRandomAlbum(); }
		else
		{
			#no more albums to play
			$ON = 0;
			::HasChanged('AlbumrandomOn');
			$selected = -1;
			Log("No infinite mode - just checking about restoring playmode");
			RestorePlaymode();
			Log("*** No more albums to play - shutting plugin off ***");
			return;
		}
	}
	
	WriteStats();
}
sub Notify
{
	my $notify_text = $_[0] if $_[0];

	return if ($ON == 0);
	return if ($::Options{OPT.'shownotifications'} == 0); 
	return if (not defined $notify_text);
	
	if (not defined $notify)
	{
		Log("Initializing notify");
		$notify=Gtk2::Notify->new('empty','empty');
		my ($name, $vendor, $version, $spec_version)= Gtk2::Notify->get_server_info;
		$Daemon_name= "$name $version ($vendor)";
		my @caps = Gtk2::Notify->get_server_caps;
		$can_body=	grep $_ eq 'body',	@caps;
		$can_actions=	grep $_ eq 'actions',	@caps;
	}

	my $notify_header = "Albumrandom";
	$notify->update($notify_header,$notify_text);
	$notify->set_timeout(4000);
	eval{$notify->show;};
	if ($@){warn "Albumrandom ERROR: \$notify didn't evaluate properly!"; Log("\$notify didn't evaluate properly (did you notice something strange? contact laite @ #gmusicbrowser)");};
	
	return 1;
}

sub Log
{
	my $text=$_[0];
	
	$Log->set( $Log->prepend,0, localtime().'  '.$text );
	if (my $iter=$Log->iter_nth_child(undef,5000)) { $Log->remove($iter); }
	
	$logContent .= localtime().' '.$text."\n";
	$logHasChanged = 1;
}

sub RecalculateButton
{
	if (CalculateDB(1) != 0) {Notify("Forced DB-update successfull");}
}

sub ToggleInfinite
{
	if ($::Options{OPT.'infinite'} == 0) { $::Options{OPT.'infinite'} = 1; Notify("Infinite mode is ON"); }
	else { $::Options{OPT.'infinite'} = 0; Notify("Infinite mode is OFF"); }
	
}

sub HasPlaymodeChanged
{
	my $success = 0;
	
	if ((!($originalModeText eq $::Options{OPT.'randommode'})) and ($originalModeText ne ''))
	{ 
		Log('Current playmode ('.$::Options{OPT.'randommode'}.') is different than DB calculation ('.$originalModeText.')');		
		return 1; 
		
	}
	else {return 0;}
	
}
sub GenerateRandomAlbum()
{
	my $amount;
	
	if ($_[0]) { $amount = $_[0]; }
	else {$amount = 1;}
	
	my $forceDB = 0;
	$ON = 1;

	if (HasPlaymodeChanged() == 1) { $forceDB = DBDialog(); }
	else { $forceDB = 0;}

	if (CalculateDB($forceDB) == 0) { Log("CalculateDB FAILED"); $ON=0; return;}
	if (CalculateAlbum($amount) == 0) { Log("CalculateAlbum FAILED"); $ON=0; return;};

	::HasChanged('AlbumrandomOn');

	if ($amount == 1) {Log("Successfully generated new album");}
	else {Log("Successfully generated multiple albums");}

	WriteStats();
	return 1;
}

sub CalculateDB
{
	my $force;
	
	if (($_[0]) and ($_[0] == 1))  { $force = 1; }
	
	if ((not defined $force) and (defined $IDs->[0]))
	{
		#don't calculate again, unless it's about time
		if ($::Options{OPT.'recalculate'} == 1)
		{
			my $updatetime = $lastDBUpdate + ($::Options{OPT.'recalculate_time'}*3600);
			if (time > $updatetime) { Log("Re-calculating DB (timed update)"); }
			else {Log("DB already calculated - will update after ".int(0.5+(($updatetime-time)/60))." minutes (timed update)");return 3;}
		}
		else {Log("DB already calculated - returning");return 2;}
	}
	elsif ((not defined $force) and (not defined $IDs->[0]) and ($::Options{OPT.'recalculate'} == 1))
	{
		#load cache if there is any - LoadDBData also checks for $lastDBUpdate and returns 0 if it's time to reupdate properly!
		if (LoadDBData() == 1) { Log('Loaded cache successfully'); return 1;}
		else { Log('Cache couldn\'t be loaded or it was too old - calculating the whole DB'); }
	}

	if (defined $force) {Log("Starting Database calculation (FORCED)");}
	else {Log("Starting Database calculation");}
	Notify('Calculating DB');
	my $al=AA::GetAAList('album');
	Log("Found ".scalar@$al." albums");

	my $totalPropability=0;
	my @albumPropabilities = ();
	my $randommode = $::Options{SavedWRandoms}{$::Options{OPT.'randommode'}};
	my $straightmode = $::Options{SavedSorts}{$::Options{OPT.'straightmode'}};
	
	if ($::Options{OPT.'randommode'} ne 'shuffle')
	{
		Log("Found RandomMode - setting originalMode to \'1\'");
		$originalMode = 1;
		::Select(sort => $randommode);
		$originalModeText = $::Options{OPT.'playmode'};

		#calculate random values according to selected mode
		foreach my $key (@$al)
		{
			my $list=AA::GetIDs('album',$key);
			my $curPropability=0;
			
			foreach my $track (@$list)	{ 
				$curPropability += $::RandomMode->CalcScore($track);
			}
			
			$curPropability /= scalar@$list;
			if ($::Options{OPT.'tweakmode'} == 1)
			{
				$curPropability = (($curPropability**$::Options{OPT.'tweak_power'})*($::Options{OPT.'tweak_multiple'}/100)); 
				if ($curPropability > 1) { $curPropability = 1; }
			}
			
			push @albumPropabilities,$curPropability;
		
			#Log("Set propability ".sprintf("%.3f",$curPropability)." for ".Songs::Get(@$list->[0],'album'));
			
			$totalPropability += $curPropability;
		}

		
	}
	else #shuffle -> treat every album as equal
	{
		Log("Shuffle selected - setting originalMode to \'0\'");
		$originalMode = 0;
		$originalModeText = 'shuffle';
				
		foreach my $a (@$al) {push @albumPropabilities,1;}
		$totalPropability = scalar@$al;
	}

	::Select(sort => $straightmode);

	Log("Total propability seems to be ".sprintf("%.3f (avg ~ %.3f)",$totalPropability,($totalPropability/scalar@$al)));
	@$IDs = (\@$al,\@albumPropabilities);

	$lastDBUpdate = time;
	Log("DB succesfully updated");
	
	SaveDBData();
	
	return 1;
}

sub CalculateAlbum
{
	my $wanted = $_[0] if ($_[0]);
	
	if (not defined $wanted) { $wanted = 1; }
	
	Log("Calculating for ".$wanted." random album");
	
	return if ($ON == 0);
	return Log("No IDs") unless @$IDs;
	
	Log("Calculating Album");
	my $previous = $selected;
	
	$selected=-1;
	my $albumAmount = -1;
	my $albumkeys = $IDs->[0];
	my $propabilities = $IDs->[1];
	my @okAlbums = ();
	
	my $songlist = $::ListPlay; 
	
	my @indices = sort { $propabilities->[$b] <=> $propabilities->[$a] } 0..(scalar@$propabilities-1);
	Log("Sorted albums' indices");

	
	#sort indices decreasing by propability if selected 'topalbums'
	if ($::Options{OPT.'topalbumsonly'} == 1)
	{
		$albumAmount = $::Options{OPT.'topalbumamount'};
		Log("Set albumlimit to ".$albumAmount." top albums");
	}

	#we find out which albums are 'ok' to choose (due to filtering/playlist)
	#don't put previously selected album to okTable, to prevent from playing same album twice in a row
	my $totalPropability = 0;
	my $oldtop=0;
	foreach my $indx (@indices)
	{
		if ($indx != $previous)
		{
			my $aID = AA::GetIDs('album', $albumkeys->[$indx]);

			if ($songlist == $::Library)
			{
					push @okAlbums, $indx;
					$totalPropability += $propabilities->[$indx];
			}
			else
			{
				my $inFilter = $songlist->AreIn($aID);
				
				if ((($::Options{OPT.'requireallinfilter'} == 1) and (scalar@$inFilter == scalar@$aID)) or (($::Options{OPT.'requireallinfilter'} == 0) and (scalar@$inFilter > 0))) 
				{
					push @okAlbums, $indx;
					$totalPropability += $propabilities->[$indx];
				}
			}
			
			if ((scalar@okAlbums<=10) and ($oldtop != scalar@okAlbums))
			{
				if (scalar@okAlbums == 1) { Log("Top albums");}
				Log(sprintf("%d. %s (%.3f)",(scalar@okAlbums),Songs::Get($aID->[0],'album'),$propabilities->[$indx]));
				$oldtop = scalar@okAlbums;
			} 	
			
		}
		if (scalar@okAlbums == $albumAmount) {Log("Found enough album for top list"); last; }
	}
	
	if (scalar@okAlbums == 0)  { Log("Error! No okAlbums in CalculateAlbum"); return 0;}
	if ($totalPropability == 0) { Log("Error! \$totalPropability == 0 in CalculateAlbum"); return 0;}
	
	Log("Generating from ".scalar@okAlbums." albums");
	Log(sprintf("Average propability for an album is ~ %.3f",($totalPropability/scalar@okAlbums)));
	
	
	if (($wanted > 1) and (scalar@okAlbums <= $wanted)) 
	{ 
			Log("All albums selected for multiple random!"); 
			MultipleAlbums(\@okAlbums); 
			return 4;
	}

	#generate random number and scroll through okTable, until $wanted is met
	my @foundAlbums = ();
	my $counter = 0;
	while ((scalar@foundAlbums < $wanted) and ($counter < 32768))
	{
		$counter++;
		my $r=rand($totalPropability);
		my $tp=0;
		my $current=-1;
		Log("Random number: ".$r." (of ".$totalPropability.")");
		
		foreach my $okA (@okAlbums)
		{
			$current++;
			$tp += $propabilities->[$okA];
			if ($tp > $r)
			{
				push @foundAlbums, $okA;
				Log ("Found ".scalar@foundAlbums.". random album (".($current+1)."/".scalar@okAlbums.")");
				last; 
			}
		}
		$totalPropability -= $propabilities->[$current];
		splice @okAlbums, $current, 1;
	}

	#if we were generating multiple albums, send them forward and exit gracefully
	if ($wanted > 1) { Log("Sending ".scalar@foundAlbums." random albums to MultipleAlbum()"); MultipleAlbums(\@foundAlbums); return 4;}

	#otherwise our only selected album should be in foundAlbums[0]
	$selected = $foundAlbums[0];
	
	my $al = AA::GetIDs('album',$IDs->[0][$selected]);
	Log("Selected album: ".Songs::Get($al->[0],'album'));
	Log("propability for selected: ".$IDs->[1][$selected]);
	
	Songs::SortList($al,'disc track file');
	my $firstSong = $al->[0];
	$lastSong = $al->[scalar@$al-1]; 
	
	Log("Found first song of the album: ".Songs::Get($firstSong,'title'));
	Log("Found last song of the album: ".Songs::Get($lastSong,'title'));

	if ($::RandomMode || $::Options{Sort}=~m/shuffle/)
	{
		Log('Changing playmode to \'straight\'');
		::Select('sort' => 'album_artist year album disc track');
	}
	::Enqueue($firstSong);
	
	Log("Random Album generation successfull!");
	return 1;
}

sub UpdateAlbumFromID
{
	my $albumID = $_[0];

	Log("Starting Album Update");
	
	my $rmtoggled = 0;

	if ($originalMode == 1)
	{
		Log("Switching to RandomMode for calculation");
		::Select(sort => $::Options{SavedWRandoms}{$::Options{OPT.'randommode'}});
		$rmtoggled = 1;
	}
	
	my $al = AA::GetIDs('album',$IDs->[0][$albumID]);
	Log("Old propability for ".Songs::Get($al->[0],'album').": ".$IDs->[1][$albumID]);
	
	my $curPropability = 0; 
	if ($::RandomMode) {
		foreach my $track (@$al) { $curPropability += $::RandomMode->CalcScore($track);}
		$curPropability /= scalar@$al;
		Log("Updating with Random Mode");
	}
	else {$curPropability = 1; Log("Updating with Straight Mode"); }
	
	$IDs->[1][$albumID] = $curPropability;
		
	Log("Updated new propability for ".Songs::Get($al->[0],'album').": ".sprintf("%.3f",$curPropability));
	
	::Select(sort => $::Options{SavedSorts}{$::Options{OPT.'straightmode'}});
	
	return 1;
}

sub MultipleAlbums()
{
	my $albumlistref = $_[0];
	Log("MultipleAlbums() here! I have ".scalar@$albumlistref." albums and I'm going to put them to static list.");
	
	my @trackIDs = ();
	foreach my $alr (@$albumlistref)
	{
		my $al = AA::GetIDs('album',$IDs->[0][$alr]);
		foreach my $trc (@$al) { push @trackIDs,$trc;}
	}
	
	if ($::Options{OPT.'multiplelist'} ne ''){::SaveList($::Options{OPT.'multiplelist'},\@trackIDs);}
	else {::SaveList('albumrandom',\@trackIDs);}
}

sub LoadDBData()
{
	return 0 unless defined $Cachefile;
	return 0 if ($::Options{OPT.'recalculate'} == 0);
	
	open my $fh,'<',$Cachefile or return 0;
	my @lines = <$fh>;
	close($fh);

	my $lastupdatetime = 0;
	
	if (!($lines[0] =~ m/^albumrandomv2\n/)) {Log("ERROR: Cachefile not written properly (couldn\'t find formatID)!"); return 0;}

	if (!($lines[1] =~ m/^(\d+)\n/)) {Log("ERROR: Cachefile not written properly (couldn\'t find updatetime)!"); return 0;}
	else 
	{
		$lastupdatetime = $1;
		my $day = int((time-$lastupdatetime)/86400); 
		my $hour = int(((time-$lastupdatetime)%86400)/3600);
		my $min = int(((time-$lastupdatetime)%3600)/60);
		Log("Found last update time: ".$lastupdatetime." (That\'s ".$day.'d '.$hour."h ".$min."min ago)");
	} 
	if (!($lines[2] =~ m/^(\d+)\t(.+)\n/)) {Log("ERROR: Cachefile not written properly (couldn\'t parse originalmode)!"); return 0;}
	else 
	{
		my $oldmode = $2;
		if ($oldmode eq $::Options{OPT.'randommode'})
		{
			$originalMode = $1;
			$originalModeText = $oldmode;
		}
		else { Log("Current playmode doesn\'t match with cache"); return 0;}
	}

	my $updatetime = $lastupdatetime + ($::Options{OPT.'recalculate_time'}*3600);
	if (time > $updatetime) { Log("Cache is too old"); return 0; }
	else { Log('Cache is OK - updating in '.($updatetime-time).' seconds'); $lastDBUpdate = $lastupdatetime;}

	my @prop = ();
	my @al = ();

	foreach my $line (@lines)
	{
		if ($line =~ m/(.+)\t(.+)\t(.+)\n/)
		{
			my $list=AA::GetIDs('album',$2);
			Songs::SortList($list,'disc track file');
			
			#filename ($3) works as a confirmating agent here, since IDs may (?) change - If found mismatch return 0;			
			if ($3 eq Songs::Get($list->[0],'fullfilename'))
			{
				push @prop, $1;
				push @al, $2;
			}
			else {Log('filename doesn\'t match!'); return 0;}
		}
	}
	@$IDs = (\@al,\@prop);

	return 1;
}

sub SaveDBData()
{
	return 'no cachefile' unless defined $Cachefile;
	return 'statwriting not enabled' if ($::Options{OPT.'writestats'} == 0);
	return 'no data to save' if (not defined $IDs->[0]);

	my $cacheContent = "albumrandomv2\n";
	$cacheContent .= $lastDBUpdate."\n";
	$cacheContent .= $originalMode."\t".$::Options{OPT.'randommode'}."\n";
	
	my $albumkeys = $IDs->[0];
	my $propabilities = $IDs->[1];
	my $current = -1;
	foreach my $key (@$albumkeys) 
	{ 
		$current++;
		my $list=AA::GetIDs('album',$key);
		Songs::SortList($list,'disc track file');
		$cacheContent .= join "\t",$propabilities->[$current],$key,Songs::Get($list->[0],'fullfilename'); 
		$cacheContent .= "\n";
	}

	open my $fh,'>',$Cachefile or warn "Error opening '$Cachefile' for writing : $!\n";
	print $fh $cacheContent or warn "Error writing to '$Cachefile' : $!\n";
	close $fh;
	
	Log("*** DB has been saved to ".$Cachefile." ***");
	
}

sub DBDialog
{
	if ($::Options{OPT.'neveraskwhenplaymodechanged'} == 1)
	{
		if ($::Options{OPT.'playmodechangedanswer'} eq 'recalculate') { Log('Re-calculating DB without asking!'); return 1; }
		else { Log('Using the old DB without asking!'); return 0;}
	}

	my $text1 = 'Your current playmode is different than original DB calculation.';
	my $text2 = 'Do you wish to re-calculate DB?';
	
	my $dialog = Gtk2::Dialog->new ('DB recalculation confirmation', undef,[qw/modal destroy-with-parent/],'gtk-yes'	=> 'yes', 'gtk-no'	=> 'no');
	$dialog->set_position('center-always');
	$dialog->set_border_width(4);

    my $label = Gtk2::Label->new();
    my $label2 = Gtk2::Label->new();
   	$label->set_label($text1);
   	$label2->set_label($text2);

    $dialog->get_content_area ()->add ($label);
    $dialog->get_content_area ()->add ($label2);
    $dialog->show_all;
    
	my $response = $dialog->run;

  	$dialog->destroy;

  	if ($response eq 'yes') { Log('Re-calculating DB (confirm dialog)'); return 1;}
  	else {Log('Using the old DB (confirm dialog)'); return 0;}
}

sub WriteStats()
{
	return 'no logfile' unless defined $Logfile;
	return 'statwriting not enabled' if ($::Options{OPT.'writestats'} == 0);
	return if ($logHasChanged == 0);

	Log("*** Stats have been written to ".$Logfile." ***");

	open my $fh,'>',$Logfile or warn "Error opening '$Logfile' for writing : $!\n";
	print $fh $logContent   or warn "Error writing to '$Logfile' : $!\n";
	close $fh;
	
	$logHasChanged = 0;
	
}

1 #the file must return true
