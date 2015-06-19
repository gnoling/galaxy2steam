#!/usr/bin/env perl
use Win32::TieRegistry(Delimiter => '/', ArrayValues => 0);
use Log::Log4perl qw/:easy/;
use Math::Int64   qw/uint64/;
use String::Similarity::Group ':all';
use Search::Tokenizer;
use Win32::Console::ANSI;
use LWP::UserAgent;
use DBI;
use JSON;

	my $db;
	my $sth;
	my $JSON;
	my $UA      = new LWP::UserAgent;
	my $prepare = 0;
	my $logger = qq(
	    log4perl.logger                    = TRACE, STDINF
	    log4perl.appender.STDINF           = Log::Log4perl::Appender::ScreenColoredLevels
	    log4perl.appender.STDINF.stderr    = 0
	    log4perl.appender.STDINF.layout    = PatternLayout
	    log4perl.appender.STDINF.layout.ConversionPattern = %x%m{chomp}%n
	);
	Log::Log4perl->init_once(\$logger);
	Log::Log4perl::NDC->push("");
	my $SS = SteamShortcuts->new() || LOGDIE "failed to load any steam users";

	if(!-f "galaxy2steam.json" || !-f "galaxy2steam.db") {
		unlink("galaxy2steam.db");
		unlink("galaxy2steam.json");
		$prepare = 1;
	}

	$db = DBI->connect("dbi:SQLite:dbname=galaxy2steam.db", "", "", { AutoCommit => 1, PrintError => 0 }) or die "failed to create galaxy2steam.db $DBI::errstr";
	$db->do("PRAGMA synchronous = OFF");
	$db->do("PRAGMA cache_size = 100000");

	if($prepare) {
		my $response = $UA->get("http://api.steampowered.com/ISteamApps/GetAppList/v0001/");
		if($response->is_success) {
			SteamShortcuts::burp('galaxy2steam.json', $response->decoded_content( charset => 'none' ));
		}
		$JSON = decode_json(slurp('galaxy2steam.json'));
		LOGDIE "failed to retrieve api applist" unless defined $JSON;
		$db->do("CREATE VIRTUAL TABLE appids USING fts4(aid, name, tokenize=perl 'Search::Tokenizer::unaccent')") or die "Failed to create virtual table";
		$db->begin_work();
		$sth = $db->prepare("INSERT INTO appids(aid, name) VALUES (?,?)");
		foreach my $item (@{ $JSON->{applist}->{apps}->{app} }) {
			$sth->execute($item->{appid}, $item->{name});
		}
		$sth->finish();
		$db->commit();
	}

	$SS->strip_category("GOG Galaxy");
	$sth = $db->prepare("SELECT aid, name FROM appids WHERE name MATCH ? ORDER BY aid+1, name DESC") or die "failed to prepare: $DBI::errstr";
	my $GAMES;
	my $GOG = $Registry->{'HKEY_LOCAL_MACHINE/SOFTWARE/Wow6432Node/GOG.com/Games'};
	INFO "processing gog galaxy data";
	SteamShortcuts::more();
	foreach my $key (keys %$GOG) {
		my $aid;
		my $name;
		my @matches;
		my $match;
		my $gog_name = $GOG->{$key}->{GAMENAME};
		my $element;
		my $score;
		my $imagedata;
		my $exe;
		$sth->execute($gog_name);
		$sth->bind_columns(undef, \$aid, \$name);
		INFO $gog_name;
		SteamShortcuts::more();
		DEBUG "possible matches";
		SteamShortcuts::more();
		while($sth->fetch()) {
		    TRACE "AID: $aid\tNAME $name";
		    $match->{$name} = $aid;
		    push @matches, $name;
		}
		SteamShortcuts::less();
		if(@matches > 0) {
			DEBUG "most probable match";
			SteamShortcuts::more();
			($element, $score) = similarest(\@matches, $gog_name);
			DEBUG "NAME:  $element";
			DEBUG "SCORE: " . int(($score*100)+.5) . "%";
			my $response = $UA->get("http://cdn.akamai.steamstatic.com/steam/apps/$match->{$element}/header.jpg");
			if($response->is_success) {
				DEBUG "IMAGE: YES <= http://cdn.akamai.steamstatic.com/steam/apps/$match->{$element}/header.jpg";
				$imagedata = $response->decoded_content( charset => 'none' );
			}
			else {
				DEBUG "IMAGE: NO";
			}
			SteamShortcuts::less();
		}
		SteamShortcuts::less();
		if(defined $GOG->{$key}->{LAUNCHPARAM} && $GOG->{$key}->{LAUNCHPARAM} !~ /^$/) {
			$exe = "\"$GOG->{$key}->{Exe}\" $GOG->{$key}->{LAUNCHPARAM}";
		}
		else {
			$exe = $GOG->{$key}->{Exe};
		}
		$SS->add_shortcut({
			'Category'     => 'GOG Galaxy',
			'icon'         => undef,
			'StartDir'     => $GOG->{$key}->{WORKINGDIR},
			'ShortcutPath' => undef,
			'AppName'      => $gog_name,
			'Exe'          => $exe,
			'GridImageRaw' => $imagedata,
		});
	}
	$sth->finish();
	$SS->save();


sub slurp {local$/=<>if local@ARGV=@_}

package SteamShortcuts;
use Win32::TieRegistry(Delimiter => '/', ArrayValues => 0);
use Log::Log4perl qw/:easy/;
use Math::Int64   qw/uint64/;
use File::Path    qw/make_path/;

    sub new {
        my $type       = shift;
	my $opt        = shift;
        my ($self)     = {};
        bless($self, $type);
	$self->{opt}   = $opt;
	DEBUG "loading steam data";
	more();
	if($self->_init()) {
		$self->_load_shortcuts();
		less();
		return $self;
	}
	else {
		less();
		return undef;
	}
    }

    sub _init {
	my $self  = shift;
	my $STEAM = $Registry->{'HKEY_CURRENT_USER/Software/Valve/Steam'};
	my $PATH  = $STEAM->{SteamPath};
	$PATH =~ s/\/$//;
	if(-d $PATH) {
		foreach my $user (sort keys %{$STEAM->{Users}}) {
			$user =~ s/\/$//;
			if(-d "$PATH/userdata/$user") {
				TRACE "found user $user => $PATH/userdata/$user";
				$self->{steam}->{users}->{$user}->{path} = "$PATH/userdata/$user";
			}
		}
		if(scalar(keys %{$self->{steam}->{users}}) == 0) {
			WARN "found steam, but no users?";
			return 0;
		}
	}
	else {
		WARN "Can't find steam at $PATH!";
		return 0;
	}
	return 1;
    }

    sub add_shortcut {
	my $self = shift;
	my $S    = shift;
	$S->{GridID} = _gridid($S->{Exe}, $S->{AppName});
	foreach my $user (keys %{$self->{steam}->{users}}) {
		push @{$self->{steam}->{users}->{$user}->{shortcuts}}, $S;
	}
    }

    sub strip_category {
	my $self = shift;
	my $cat  = shift;
	foreach my $user (keys %{$self->{steam}->{users}}) {
		my @S = @{$self->{steam}->{users}->{$user}->{shortcuts}};
		undef $self->{steam}->{users}->{$user}->{shortcuts};
		foreach my $item (@S) {
			if($item->{Category} !~ /^$cat$/i) {
				push @{$self->{steam}->{users}->{$user}->{shortcuts}}, $item;
			}
			else {
				DEBUG "removing $item->{AppName} from category $cat";
			}
		}
	}
    }

    sub save {
	my $self = shift;
	foreach my $user (keys %{$self->{steam}->{users}}) {
		my $file = "$self->{steam}->{users}->{$user}->{path}/config/shortcuts.vdf";
		my $OUT = "\x00shortcuts\x00";
		for(my $i = 0; $i < @{$self->{steam}->{users}->{$user}->{shortcuts}}; $i++) {
			my $S = $self->{steam}->{users}->{$user}->{shortcuts}->[$i];
			next unless defined $S->{Category};
			$OUT .= "\x00$i\x00";
			foreach my $N (qw/AppName Exe StartDir icon ShortcutPath/) {
				$OUT .= "\x01$N\x00$S->{$N}\x00";
			}
			$OUT .= "\x00tags\x00\x01" . "0" . "\x00$S->{Category}\x00\x08\x08";
			if(defined $S->{GridImageRaw}) {
				if(!-d "$self->{steam}->{users}->{$user}->{path}/config/grid") {
					make_path("$self->{steam}->{users}->{$user}->{path}/config/grid");
				}
				rburp("$self->{steam}->{users}->{$user}->{path}/config/grid/$S->{GridID}.jpg", $S->{GridImageRaw});
			}
		}
		$OUT .= "\x08\x08\x0a";
		INFO "saving $file";
		rburp($file, $OUT);
	}
    }

    sub _load_shortcuts {
	my $self = shift;
	DEBUG "loading shortcuts";
	more();
	foreach my $user (keys %{$self->{steam}->{users}}) {
		if(-f "$self->{steam}->{users}->{$user}->{path}/config/shortcuts.vdf") {
			my $file = "$self->{steam}->{users}->{$user}->{path}/config/shortcuts.vdf";
			DEBUG "reading $file";
			more();
			open my $fh, '<', $file or die "failed to open shortcuts.vdf: $!";
			binmode($fh);
			my $buffer;
			my $struct;
			my $temp;
			my $header;
			my $idx;
			my $entry;
			while(read($fh, $buffer, 1024)) {
				foreach my $b (split //, $buffer) {
					if(!defined $header && defined $temp && $temp =~ /\x00(.*)\x00/) {
						$header = $1;
						$struct->{$header} = [];
						undef $temp;
					}
					elsif(defined $struct && !defined $idx) {
						if($temp =~ /\x00(.*)\x00/) {
							$idx = $1;
							undef $temp;
						}
					}
					elsif(defined $idx) {
						if($temp =~ /\x01(.*)\x00([^\x00\x08]*)[\x00\x08]/) {
							my $key = $1;
							my $val = $2;
							if($key eq "0") {
								$key = 'Category';
							}
							$entry->{$key} = $val;
							if($b eq "\x08") {
								$entry->{GridID} = _gridid($entry->{Exe}, $entry->{AppName});
								$struct->{$header}->[$idx] = $entry;
								undef $entry;
								undef $idx;
							}
							undef $temp;
						}
					}
					$temp .= $b;
				}
			}
			close $fh;
			$self->{steam}->{users}->{$user}->{shortcuts} = $struct->{shortcuts};
			less();
		}
	}
	less();
    }

    sub _gridid {
	my $cmd   = shift;
	my $name  = shift;
	my $c = uint64(_mycrc32($cmd.$name));
	my $d = $c | 0x80000000;
	my $e = ($d << 32) | 0x02000000;
	return $e;
    }

    sub _mycrc32 {
	my ($input, $init_value, $polynomial) = @_;
	$init_value = 0          unless (defined $init_value);
	$polynomial = 0xedb88320 unless (defined $polynomial);
	my @lookup_table;
	for (my $i=0; $i<256; $i++) {
		my $x = $i;
		for (my $j=0; $j<8; $j++) {
			if ($x & 1) {
				$x = ($x >> 1) ^ $polynomial;
			}
			else {
				$x = $x >> 1;
			}
		}
		push @lookup_table, $x;
	}
	my $crc = $init_value ^ 0xffffffff;
	foreach my $x (unpack ('C*', $input)) {
		$crc = (($crc >> 8) & 0xffffff) ^ $lookup_table[ ($crc ^ $x) & 0xff ];
	}
	$crc = $crc ^ 0xffffffff;
	return $crc;
    }

sub more { Log::Log4perl::NDC->push("  "); }
sub less { Log::Log4perl::NDC->pop(); }
sub burp  {my($file_name)=shift;open(my $fh,">$file_name")||die "can't create $file_name $!";print $fh @_;}
sub rburp {my($file_name)=shift;open(my $fh,">:raw","$file_name")||die "can't create $file_name $!";binmode $fh;print $fh @_;}

1;
