#! /usr/bin/perl -w -I../../lib

use utf8;
use CGI qw(:cgi header);
#use CGI::Carp qw(warningsToBrowser fatalsToBrowser);
use CGI::Carp qw(fatalsToBrowser);
use Time::localtime;
use POSIX qw(strftime);
use Encode qw(_utf8_on);
use JSON;
use JSON_bool;
use Datenbank;
use DatenbankAktualisieren;
use Trialtool;
use Auswertung;
use Tag;
use Compress::Zlib;
use MIME::Base64;
use JSON::Patch;
use HTTPError;
#use Data::Dumper;
use strict;

my $trace_sql = $cgi_verbose;

binmode STDOUT, ':encoding(utf8)';

# Brauchen wir "mysql_bind_type_guessing" für die Abfrageparameter, damit mysql
# seine Indizes ordentlich verwendet?

my $dbh = DBI->connect("DBI:$database", $username, $password, { PrintError => 1, RaiseError => 1,
								AutoCommit => 1, db_utf8($database) })
    or die "Could not connect to database: $DBI::errstr\n";

trace_sql $dbh, $trace_sql, \*STDERR
    if $trace_sql;

my $q = CGI->new;
my $op = ($q->request_method() // 'GET') . '/' . $q->url_param('op')
    or die "Keine Operation angegeben.\n";

my $do_sql = sub () {
    my ($sql, $args, $from) = @_;

    print STDERR "    # UPDATE FROM " .
	    join(", ", map {
		$_->[0] . " = " . sql_value($_->[1])
	    } @$from) . "\n"
	if $from && $trace_sql;

    $dbh->do($sql, undef, @$args);
};

sub parameter($@) {
    my $q = shift;
    my @params;
    foreach my $name (@_) {
	my $value = $q->url_param($name);
	die "Parameter $name nicht angegeben.\n"
	    unless defined $value;
	push @params, $value;
    }
    return @params;
}

sub get_fahrer($$$;$$) {
    my ($dbh, $id, $startnummer, $richtung, $starter) = @_;
    my $result;

    my $fahrer_nach_startnummer =
	fahrer_aus_datenbank($dbh, $id, $startnummer, $richtung, $starter);
    my $startnummern = [ keys %$fahrer_nach_startnummer ];
    $result = $fahrer_nach_startnummer->{$startnummern->[0]}
	if @$startnummern == 1;
    return $result;
}

sub veranstaltung_reset($$$) {
    my ($dbh, $id, $reset) = @_;
    my $sth;

    die "Unbekannte Reset-Operation\n"
	unless ($reset =~ /^(start|nennbeginn|stammdaten)$/);

    my $startnummer_max;
    if ($reset eq 'stammdaten') {
	$sth = $dbh->prepare(q{
	    SELECT MAX(startnummer)
	    FROM fahrer
	    WHERE id = ?
	});
	$sth->execute($id);
	($startnummer_max) = $sth->fetchrow_array
	    or die "Konnte die minimale und maximale Startnummer nicht ermitteln\n";
	$reset = 'nennbeginn'
	    if $startnummer_max <= 0;
	for my $table (qw(fahrer fahrer_wertung)) {  # neue_startnummer punkte runde
	    $dbh->do(qq{
		UPDATE $table
		SET startnummer = CASE WHEN startnummer < 0
				       THEN startnummer - ?
				       ELSE -startnummer END
		WHERE id = ?
	    }, undef, $startnummer_max, $id);
	}
	$dbh->do(q{
	    DELETE FROM neue_startnummer
	    WHERE id = ?
	}, undef, $id);
    }
    $dbh->do(q{
	DELETE FROM punkte
	WHERE id = ?
    }, undef, $id);
    $dbh->do(q{
	DELETE FROM runde
	WHERE id = ?
    }, undef, $id);
    $dbh->do(q{
	UPDATE fahrer_wertung
	SET wertungsrang = NULL, wertungspunkte = NULL
	WHERE id = ?
    }, undef, $id);
    $dbh->do(q{
	UPDATE fahrer
	SET version = version + 1, runden = NULL, s0 = NULL, s1 = NULL,
	    s2 = NULL, s3 = NULL, s4 = NULL, s5 = NULL,
	    zusatzpunkte = 0, punkte = NULL, ausfall = 0, stechen = 0,
	    rang = NULL, startzeit = NULL, zielzeit = NULL
	    } . ($reset eq 'start' ? '' : (
		q{
		    , nennungseingang = 0, start = 0, start_morgen = 0
		    , nenngeld = NULL
		})) . q{
	WHERE id = ?
    }, undef, $id);
    $sth = $dbh->do(q{
	DELETE FROM sektion_aus_wertung
	WHERE id = ?
    }, undef, $id);

    if ($reset eq 'nennbeginn') {
	$sth = $dbh->prepare(q{
	    SELECT basis.id
	    FROM veranstaltung
	    JOIN veranstaltung AS basis ON veranstaltung.basis = basis.tag
	    JOIN veranstaltung_feature AS basis_feature ON basis.id = basis_feature.id
	    WHERE veranstaltung.id = ? AND feature = 'start_morgen'
	});
	$sth->execute($id);
	if (my @row = $sth->fetchrow_array) {
	    my $basis_id = $row[0];
	    # Feld start in aktueller Veranstaltung auf
	    # start_morgen von vorheriger Veranstaltung setzen
	    $dbh->do(q{
		UPDATE fahrer
		JOIN fahrer AS basis USING (startnummer)
		SET fahrer.nennungseingang = 1, fahrer.start = 1
		WHERE fahrer.id = ? AND basis.id = ? AND basis.start_morgen
	    }, undef, $id, $basis_id);
	}

	$dbh->do(q{
	    DELETE FROM veranstaltung_feature
	    WHERE id = ? and feature = 'start_morgen'
	}, undef, $id);
    }

    $dbh->do(q{
	INSERT IGNORE INTO veranstaltung_feature (id, feature)
	VALUES (?, ?)
    }, undef, $id, 'sektionen_aus_wertung');

    # FIXME: In veranstaltung mtime zurücksetzen
}

sub veranstaltung_tag_to_id($$) {
    my ($dbh, $tag) = @_;

    my $sth = $dbh->prepare(q{
	SELECT id
	FROM veranstaltung
	WHERE tag = ?
    });
    $sth->execute($tag);
    my ($id) = $sth->fetchrow_array;
    return $id;
}

sub export($) {
    my ($id) = @_;
    my $result;

    $result = {
	format => 'trial-auswertung 1',
	veranstaltung => cfg_aus_datenbank($dbh, $id, 1),
	fahrer => fahrer_aus_datenbank($dbh, $id),
	vareihen => vareihen_aus_datenbank($dbh, $id)
    };
    foreach my $vareihe (@{$result->{vareihen}}) {
	delete $vareihe->{version};
    }
    $result->{veranstaltung}{basis} = $result->{veranstaltung}{basis}{tag};
    delete $result->{veranstaltung}{dateiname};
    delete $result->{veranstaltung}{id};
    return $result;
}

sub cfg_export($$$) {
    my ($id, $headers, $dateiname) = @_;
    my $cfg = cfg_aus_datenbank($dbh, $id);

    $headers->{'Content-Type'} = 'application/octet-stream';
    $dateiname //= 'Trial.cfg';
    $headers->{'Content-Disposition'} = "attachment; filename=\"$dateiname\"";

    return cfg_datei_daten($cfg);
}

sub dat_export($$$) {
    my ($id, $headers, $dateiname) = @_;
    my $cfg = cfg_aus_datenbank($dbh, $id);
    my $fahrer_nach_startnummer = fahrer_aus_datenbank($dbh, $id);

    $headers->{'Content-Type'} = 'application/octet-stream';
    $dateiname //= 'Trial.dat';
    $headers->{'Content-Disposition'} = "attachment; filename=\"$dateiname\"";

    return dat_datei_daten($cfg, $fahrer_nach_startnummer);
}

sub importieren($$$$) {
    my ($alt, $neu, $tag, $create) = @_;
    my $veranstaltung = $neu->{veranstaltung};
    my $id;

    unless ($tag) {
	$veranstaltung->{tag} = random_tag(16);
	$veranstaltung->{wertungen}[0]{titel} .= ' (Kopie)';
	$veranstaltung->{aktiv} = json_bool(1);
	$veranstaltung->{version} = 1;
	#$veranstaltung->{fahrer_version} = 1;
	foreach my $fahrer (values %{$neu->{fahrer}}) {
	    $fahrer->{version} = 1;
	}
    }

    if ($tag && defined $veranstaltung->{tag}) {
	$id = veranstaltung_tag_to_id($dbh, $veranstaltung->{tag});
	die HTTPError->new('403 Duplicate Event', 'Veranstaltung existiert bereits')
	    if $create && defined $id;
    }
    if (defined $id) {
	if ($alt) {
	    $alt->{veranstaltung}{basis} = { tag => $alt->{veranstaltung}{basis} }
		if defined $alt->{veranstaltung}{basis};
	} else {
	    $alt = {
		veranstaltung => cfg_aus_datenbank($dbh, $id, 1),
		fahrer => fahrer_aus_datenbank($dbh, $id),
	    };
	}
	die "Synchronisieren in diese Veranstaltung nicht erlaubt\n"
	    if $tag && !$alt->{veranstaltung}{sync_erlaubt};
    } else {
	my $sth = $dbh->prepare(q{
	    SELECT MAX(id)
	    FROM veranstaltung
	});
	$sth->execute;
	my @row = $sth->fetchrow_array;
	$id = ($row[0] // 0) + 1;
	$veranstaltung->{id} = $id;
    }
    $veranstaltung->{basis} = { tag => $veranstaltung->{basis} }
	if defined $veranstaltung->{basis};
    if ($tag) {
	$veranstaltung->{sync_erlaubt} = json_bool(1);
    }
    veranstaltung_aktualisieren $do_sql, $id, $alt->{veranstaltung}, $veranstaltung, 0;
    fahrer_aktualisieren $do_sql, $id, $alt->{fahrer}, $neu->{fahrer}, 0;
    my $sth = $dbh->prepare(q{
	SELECT vareihe
	FROM vareihe_veranstaltung
	WHERE id = ?
    });
    $sth->execute($id);
    my $vareihen = {};
    for (my @row = $sth->fetchrow_array) {
	$vareihen->{$row[0]} = 1;
    }
    foreach my $data (@{$neu->{vareihen}}) {
	my $sth = $dbh->prepare(q{
	    SELECT vareihe
	    FROM vareihe
	    WHERE tag = ?
	});
	$sth->execute($data->{tag});
	my ($data0, $data1);
	my $vareihe;
	if (($vareihe) = $sth->fetchrow_array) {
	    $data0 = vareihe_aus_datenbank($dbh, $vareihe);
	    $data1 = { %$data0 };
	    $data1->{veranstaltungen} = [ @{$data1->{veranstaltungen}} ];
	    $data1->{startnummern} = { %{$data1->{startnummern}} };
	} else {
	    print STDERR "Veranstaltungsreihe mit Tag $data1->{tag} " .
		  "nicht gefunden\n";
	    my $sth = $dbh->prepare(q{
		SELECT MAX(vareihe)
		FROM vareihe
	    });
	    $sth->execute;
	    my @row = $sth->fetchrow_array;
	    $vareihe = ($row[0] // 0) + 1;
	    $data1 = { %$data };
	    $data1->{veranstaltungen} = [ ];
	    $data1->{startnummern} = { };
	}
	$data1->{startnummern}{$id} = $data->{startnummern};
	push @{$data1->{veranstaltungen}}, $id;
	vareihe_aktualisieren $do_sql, $vareihe, $data0, $data1, 1;
	delete $vareihen->{$vareihe};
    }
    foreach my $vareihe (keys %$vareihen) {
	$dbh->do(q{
	    DELETE FROM vareihe_veranstaltung
	    WHERE id = ?
	}, undef, $id);
	$dbh->do(q{
	    UPDATE vareihe
	    SET version = version + 1
	    WHERE vareihe = ?
	}, undef, $vareihe);
    }
    wertung_aktualisieren $dbh, $do_sql, $id;
    return { id => $id };
}

my $result;
my $headers = {
    'Content-Type' => 'application/json',
    'status' => '200 OK',
};
if (exists $ENV{'HTTP_ORIGIN'}) {
    $headers->{'Access-Control-Allow-Origin'} = $ENV{'HTTP_ORIGIN'};
    $headers->{'Access-Control-Allow-Credentials'} = 'true';
    $headers->{'Access-Control-Allow-Methods'} = 'GET, POST, PUT, DELETE';
    $headers->{'Access-Control-Allow-Headers'} = 'Content-Type';  # ', Accept'
    $headers->{'Access-Control-Max-Age'} = 3600;
}
my $json = JSON->new;
eval {
    if ($op eq 'GET/vareihen') {
	my $sth = $dbh->prepare(q{
	    SELECT vareihe, bezeichnung, kuerzel, verborgen
	    FROM vareihe
	    ORDER BY vareihe
	});
	$sth->execute();
	$result = [];
	while (my $vareihe = $sth->fetchrow_hashref) {
	    fixup_hashref($sth, $vareihe);
	    push @$result, $vareihe;
	}
    } elsif ($op eq "GET/veranstaltungen") {
	my $sth = $dbh->prepare(q{
	    SELECT id, tag, datum, dateiname, titel, aktiv
	    FROM veranstaltung
	    LEFT JOIN wertung USING (id)
	    WHERE wertung = 1
	    ORDER BY datum, titel, id
	});
	$sth->execute();
	$result = [];
	my $veranstaltungen;
	while (my $veranstaltung = $sth->fetchrow_hashref) {
	    fixup_hashref($sth, $veranstaltung);
	    my $id = $veranstaltung->{id};
	    $veranstaltung->{vareihen} = [];
	    $veranstaltung->{verborgen} = json_bool(0);
	    $veranstaltungen->{$id} = $veranstaltung;
	    push @$result, $veranstaltung;
	}

	$sth = $dbh->prepare(q{
	    SELECT id, vareihe, kuerzel, verborgen
	    FROM vareihe_veranstaltung
	    JOIN vareihe USING (vareihe)
	    ORDER BY id, vareihe
	});
	$sth->execute();
	while (my @row = $sth->fetchrow_array) {
	    fixup_arrayref($sth, \@row);
	    my $veranstaltung = $veranstaltungen->{$row[0]};
	    if ($veranstaltung) {
		push @{$veranstaltung->{vareihen}},
		    { vareihe => $row[1], kuerzel => $row[2] }
		    if defined $row[2] && $row[2] ne "";
		$veranstaltung->{verborgen} = $row[3]
		    if $row[3];
	    }
	}
    } elsif ($op =~ q<^GET/(|vorheriger/|naechster/)fahrer$>) {
	    my ($id, $startnummer) = parameter($q, qw(id startnummer));
	    $result = get_fahrer($dbh, $id, $startnummer,
		$1 eq 'vorheriger/' ? -1 : $1 eq 'naechster/' ? 1 : undef);
    } elsif ($op =~ q<^GET/(vorheriger/|naechster/)starter$>) {
	    my ($id, $startnummer) = parameter($q, qw(id startnummer));
	    $result = get_fahrer($dbh, $id, $startnummer,
		$1 eq 'vorheriger/' ? -1 : $1 eq 'naechster/' ? 1 : undef, 1);
    } elsif ($op eq "GET/veranstaltung") {
	my ($id) = parameter($q, qw(id));
	$result = cfg_aus_datenbank($dbh, $id, 1);
    } elsif ($op eq "GET/veranstaltung/export") {
	my $id;
	eval {
	    my ($tag) = parameter($q, qw(tag));
	    $id = veranstaltung_tag_to_id($dbh, $tag);
	};
	if ($@) {
	    ($id) = parameter($q, qw(id));
	}
	$dbh->begin_work;
	$result = export($id);
	delete $result->{veranstaltung}{sync_erlaubt};
	my $dateiname = $q->url_param('name') // 'Trial.tra';
	$dbh->commit;
	$headers->{'Content-Type'} = 'application/octet-stream';
	$headers->{'Content-Disposition'} = "attachment; filename=\"$dateiname\"";
	$result = "/* $result->{format} */\n" . $json->canonical->encode($result);
	$result = Encode::encode_utf8($result);
	$result = Compress::Zlib::memGzip($result);
    } elsif ($op eq "GET/trialtool/cfg") {
	my ($id) = parameter($q, qw(id));
	$dbh->begin_work;
	$result = cfg_export($id, $headers, $q->url_param('name'));
	$dbh->commit;
    } elsif ($op eq "GET/trialtool/dat") {
	my ($id) = parameter($q, qw(id));
	$dbh->begin_work;
	$result = dat_export($id, $headers, $q->url_param('name'));
	$dbh->commit;
    } elsif ($op eq "OPTIONS/veranstaltung/import") {
    } elsif ($op eq "POST/veranstaltung/import") {
	my $data = decode_base64($q->param('POSTDATA'));
	$data = Compress::Zlib::memGunzip($data)
	    or die "Daten konnten nicht dekomprimiert werden\n";
	_utf8_on($data);
	$data = $json->decode($data)
	    or die "Daten konnten nicht decodiert werden\n";
	if (ref($data) ne "HASH" ||
	    $data->{format} ne "trial-auswertung 1" ||
	    ref($data->{veranstaltung}) ne "HASH" ||
	    ref($data->{fahrer}) ne "HASH" ||
	    ref($data->{vareihen}) ne "ARRAY") {
	    die "Datenformat nicht unterstützt\n";
	}

	# Wenn der Tag existiert, wird diese Veranstaltung aktualisiert!
	my $tag = $q->url_param('tag');
	$data->{veranstaltung}{tag} = $tag
	    if defined $tag;
	my $create = $q->url_param('create');

	$dbh->begin_work;
	$result = importieren(undef, $data, defined $tag, defined $create);
	$dbh->commit;
	$headers->{status} = '200 Modified';
    } elsif ($op eq "POST/trialtool/import") {
	my $data = $json->decode($q->param('POSTDATA'))
	    or die "Daten konnten nicht decodiert werden\n";
	if (ref($data) ne "HASH" ||
	    !$data->{cfg} || !$data->{dat}) {
	    die "Übertragungsformat nicht unterstützt\n";
	}
	$data->{cfg} = decode_base64($data->{cfg})
	    or die "Daten konnten nicht decodiert werden\n";
	$data->{dat} = decode_base64($data->{dat})
	    or die "Daten konnten nicht decodiert werden\n";

	my $veranstaltung = cfg_parsen($data->{cfg});
	my $fahrer = dat_parsen($data->{dat}, $veranstaltung, 0);
	# $veranstaltung->{datum}, $veranstaltung->{mtime}
	$dbh->begin_work;
	$result = importieren(undef, {veranstaltung => $veranstaltung, fahrer => $fahrer, vareihen => []}, 0, 0);
	$dbh->commit;
	$headers->{status} = '200 Modified';
    } elsif ($op eq "GET/veranstaltung/vorschlaege") {
	my @params = parameter($q, qw(id));
	foreach my $feld (qw(bundesland land fahrzeug club)) {
	    my $sth = $dbh->prepare(qq{
		SELECT $feld
		FROM (
		    SELECT $feld
		    FROM fahrer
		    WHERE id = ? AND $feld IS NOT NULL AND $feld <> ''
		    GROUP BY $feld
		    ORDER BY COUNT($feld) DESC
		    LIMIT 100 ) as _
		ORDER by $feld
	    });
	    $sth->execute(@params);
	    my $felder = [];
	    while (my @row = $sth->fetchrow_array) {
		fixup_arrayref($sth, \@row);
		push @$felder, $row[0];
	    }
	    $result->{$feld} = $felder;
	}
    } elsif ($op eq "GET/startnummer") {
	my ($id, $startnummer) = parameter($q, qw(id startnummer));
	my $sth = $dbh->prepare(qq{
	    SELECT startnummer, klasse, nachname, vorname, geburtsdatum
	    FROM fahrer
	    WHERE id = ? AND startnummer = ?
	});
	$sth->execute($id, $startnummer);
	if (my $row = $sth->fetchrow_hashref) {
	    fixup_hashref($sth, $row);
	    $result = $row;

	    my $sth = $dbh->prepare(qq{
		SELECT f1.startnummer + 1
		FROM
		    ( SELECT startnummer
		    FROM fahrer
		    WHERE id = ?
		    AND startnummer >= ? ) AS f1
		LEFT JOIN
		    ( SELECT startnummer
		    FROM fahrer
		    WHERE id = ?
		    AND startnummer >= ? ) AS f2
		ON f1.startnummer + 1 = f2.startnummer
		WHERE f2.startnummer IS NULL
		ORDER BY f1.startnummer
		LIMIT 1
	    });
	    $sth->execute($id, $startnummer, $id, $startnummer);
	    my @row = $sth->fetchrow_array;
	    fixup_arrayref($sth, \@row);
	    $result->{naechste_startnummer} = $row[0];
	}
    } elsif ($op eq "PUT/fahrer") {
	my ($id, $version) = parameter($q, qw(id version));
	my $startnummer = $q->url_param('startnummer');  # Alte Startnummer
	my $putdata = $q->param('PUTDATA');
	_utf8_on($putdata);
	my $fahrer1 = $json->decode($putdata);

	print STDERR "Fahrer: $putdata\n"
	    if $cgi_verbose;

	die "Ungültige Startnummer\n"
	    if defined $fahrer1->{startnummer} &&
	       $fahrer1->{startnummer} !~ /^-?\d+$/;

	my $fahrer0;
	$dbh->begin_work;
	if (defined $startnummer) {
	    my $fahrer_nach_startnummer =
		fahrer_aus_datenbank($dbh, $id, $startnummer);
	    $fahrer0 = $fahrer_nach_startnummer->{$startnummer};
	    die HTTPError->new('409 Conflict', 'Invalid Row Version')
		if $fahrer0->{version} != $version;
	}
	unless (defined $fahrer1->{startnummer}) {
	    my $sth = $dbh->prepare(qq{
		SELECT MIN(startnummer)
		FROM fahrer
		WHERE id = ?
	    });
	    $sth->execute($id);
	    if (my @row = $sth->fetchrow_array) {
		$fahrer1->{startnummer} = $row[0] < 0 ? $row[0] - 1 : -1;
	    } else {
		die "Konnte keine freie negative Startnummer finden\n";
	    }
	}
	einen_fahrer_aktualisieren $do_sql, $id, $fahrer0, $fahrer1, 1;
	wertung_aktualisieren $dbh, $do_sql, $id;

	my $mtime = $q->url_param('mtime');
	if ($mtime) {
	    $mtime = strftime("%Y-%m-%d %H:%M:%S", @{localtime($mtime)});
	    $dbh->do(q{
		UPDATE veranstaltung
		SET mtime = ?
		WHERE id = ?
	    }, undef, $mtime, $id);
	}
	$dbh->commit;

	$headers->{status} = $fahrer0 ? '200 Modified' : '201 Created';
	$startnummer = $fahrer1->{startnummer};
	$result = get_fahrer($dbh, $id, $startnummer);
    } elsif ($op eq "PUT/veranstaltung") {
	my ($version) = parameter($q, qw(version));
	my $id = $q->url_param('id');  # Alte ID
	my $putdata = $q->param('PUTDATA');
	_utf8_on($putdata);
	my $cfg1 = $json->decode($putdata);

	print STDERR "Veranstaltung: $putdata\n"
	    if $cgi_verbose;

	my $cfg0;
	my $id_neu;

	my $mtime = $q->url_param('mtime');
	if ($mtime) {
	    $cfg1->{mtime} = strftime("%Y-%m-%d %H:%M:%S", @{localtime($mtime)});
	}

	$dbh->begin_work;
	if (defined $id) {
	    $id_neu = $id;
	} else {
	    my $sth = $dbh->prepare(qq{
		SELECT MAX(id)
		FROM veranstaltung
	    });
	    $sth->execute();
	    my @row = $sth->fetchrow_array
		or die "Konnte keine freie ID finden\n";
	    $id_neu = ($row[0] // 0) + 1;
	}
	if (!defined $id && defined $cfg1->{basis}{tag}) {
	    my $basis_id = veranstaltung_tag_to_id($dbh, $cfg1->{basis}{tag});
	    die "Basis-Veranstaltung $cfg1->{basis}{tag} nicht gefunden\n"
		unless defined $basis_id;
	    veranstaltung_duplizieren($do_sql, $basis_id, $id_neu);
	    $cfg1->{tag} = random_tag(16);
	    $version = 1;
	}
	if (defined $id || defined $cfg1->{basis}{id}) {
	    $cfg0 = cfg_aus_datenbank($dbh, $id_neu, 1);
	    die HTTPError->new('409 Conflict', 'Invalid Row Version')
		if $cfg0->{version} != $version;
	}
	veranstaltung_aktualisieren $do_sql, $id_neu, $cfg0, $cfg1, 1;
	veranstaltung_reset($dbh, $id_neu, $cfg1->{reset})
	    if exists $cfg1->{reset} && $cfg1->{reset} ne "";
	wertung_aktualisieren $dbh, $do_sql, $id_neu;
	$dbh->commit;
	$id = $id_neu;

	$headers->{status} = $cfg0 ? '200 Modified' : '201 Created';
	$result = cfg_aus_datenbank($dbh, $id, 1);
    } elsif ($op eq "PUT/vareihe") {
	my ($version) = parameter($q, qw(version));
	my $vareihe = $q->url_param('vareihe');  # Alte vareihe-ID
	my $putdata = $q->param('PUTDATA');
	_utf8_on($putdata);
	my $data1 = $json->decode($putdata);

	print STDERR "Veranstaltungsreihe: $putdata\n"
	    if $cgi_verbose;

	my $data0;
	$dbh->begin_work;

	if (defined $vareihe) {
	    $data0 = vareihe_aus_datenbank($dbh, $vareihe);
	    die HTTPError->new('409 Conflict', 'Invalid Row Version')
		if $data0->{version} != $version;
	}
	unless (defined $vareihe) {
	    my $sth = $dbh->prepare(qq{
		SELECT MAX(vareihe)
		FROM vareihe
	    });
	    $sth->execute();
	    my @row = $sth->fetchrow_array
		or die "Konnte keine freie vareihe-ID finden\n";
	    $vareihe = ($row[0] // 0) + 1;
	}
	vareihe_aktualisieren $do_sql, $vareihe, $data0, $data1, 1;
	$dbh->commit;

	$headers->{status} = $data0 ? '200 Modified' : '201 Created';
	$result = vareihe_aus_datenbank($dbh, $vareihe);
    } elsif ($op eq "DELETE/fahrer") {
	my ($id, $version, $startnummer) = parameter($q, qw(id version startnummer));

	$dbh->begin_work;
	my $sth = $dbh->prepare(qq{
	    DELETE FROM fahrer
	    WHERE id = ? AND startnummer = ? AND version = ?
	});
	die HTTPError->new('409 Conflict', 'Invalid Row Version')
	    if $sth->execute($id, $startnummer, $version) != 1;
	foreach my $tabelle (qw(fahrer_wertung punkte runde neue_startnummer)) {
	    my $sth = $dbh->prepare(qq{
		DELETE FROM $tabelle
		WHERE id = ? AND startnummer = ?
	    });
	    $sth->execute($id, $startnummer);
	}
	wertung_aktualisieren $dbh, $do_sql, $id;
	$dbh->commit;

	$headers->{status} = '200 Deleted';
    } elsif ($op eq "DELETE/veranstaltung") {
	my ($id, $version) = parameter($q, qw(id version));

	$dbh->begin_work;
	my $sth = $dbh->prepare(qq{
	    DELETE FROM veranstaltung
	    WHERE id = ? AND version = ?
	});
	die HTTPError->new('409 Conflict', 'Invalid Row Version')
	    if $sth->execute($id, $version) != 1;
	foreach my $tabelle (qw(fahrer fahrer_wertung klasse punkte runde
				sektion veranstaltung_feature kartenfarbe
				wertung wertungspunkte neue_startnummer
				vareihe_veranstaltung sektion_aus_wertung)) {
	    my $sth = $dbh->prepare(qq{
		DELETE FROM $tabelle
		WHERE id = ?
	    });
	    $sth->execute($id);
	}
	$dbh->commit;

	$headers->{status} = '200 Deleted';
    } elsif ($op eq "DELETE/vareihe") {
	my ($vareihe, $version) = parameter($q, qw(vareihe version));

	$dbh->begin_work;
	my $sth = $dbh->prepare(qq{
	    DELETE FROM vareihe
	    WHERE vareihe = ? AND version = ?
	});
	die HTTPError->new('409 Conflict', 'Invalid Row Version')
	    if $sth->execute($vareihe, $version) != 1;
	foreach my $tabelle (qw(vareihe_veranstaltung vareihe_klasse)) {
	    my $sth = $dbh->prepare(qq{
		DELETE FROM $tabelle
		WHERE vareihe = ?
	    });
	    $sth->execute($vareihe);
	}
	$dbh->commit;

	$headers->{status} = '200 Deleted';
    } elsif ($op eq "POST/veranstaltung/reset") {
	my ($id, $version, $reset) = parameter($q, qw(id version reset));

	$dbh->begin_work;
	my $sth = $dbh->prepare(q{
	    SELECT version FROM veranstaltung
	    WHERE id = ?
	});
	$sth->execute($id);
	my ($version0) = $sth->fetchrow_array
	    or die "Veranstaltung nicht gefunden\n";
	die HTTPError->new('409 Conflict', 'Invalid Row Version')
	    if $version0 != $version;
	veranstaltung_reset($dbh, $id, $reset);
	$dbh->commit;

	$headers->{status} = '200 Modified';
    } elsif ($op eq "GET/fahrer/suchen") {
	my ($id, $suchbegriff) = parameter($q, qw(id suchbegriff));
	my $select_fahrer = q{
	    SELECT startnummer, nachname, vorname, geburtsdatum, klasse
	    FROM fahrer
	};
	$result = [];
	if ($suchbegriff =~ /^-?\d+$/) {
	    my $sth = $dbh->prepare($select_fahrer . q{
		WHERE id = ? AND startnummer = ?
	    });
	    $sth->execute($id, $suchbegriff);
	    while (my $row = $sth->fetchrow_hashref) {
		fixup_hashref($sth, $row);
		push @$result, $row;
	    }
	}
	unless (@$result) {
	    $suchbegriff =~ s/^\s+//;
	    $suchbegriff =~ s/\s+$//;
	    $suchbegriff =~ s/\s+/% /g;
	    $suchbegriff =~ s/\*/%/g;
	    $suchbegriff = "$suchbegriff%";

	    my $sth = $dbh->prepare($select_fahrer . q{
		WHERE id = ? AND
		      (CONCAT(COALESCE(vorname, ''), ' ', COALESCE(nachname, '')) LIKE ? OR
		       CONCAT(COALESCE(nachname, ''), ' ', COALESCE(vorname, '')) LIKE ?)
		ORDER BY nachname, vorname
		LIMIT 20
	    });
	    $sth->execute($id, $suchbegriff, $suchbegriff);
	    while (my $row = $sth->fetchrow_hashref) {
		fixup_hashref($sth, $row);
		push @$result, $row;
	    }
	}
    } elsif ($op eq "GET/vareihe") {
	my ($vareihe) = parameter($q, qw(vareihe));
	$result = vareihe_aus_datenbank($dbh, $vareihe);
	unless ($result) {
	    die HTTPError->new('404 Not Found', "Veranstaltungsreihe $vareihe nicht gefunden");
	}
    } elsif ($op eq "GET/veranstaltung/liste") {
	my ($id) = parameter($q, qw(id));
	$dbh->begin_work;
	my $sth = $dbh->prepare(qq{
	    SELECT startnummer, klasse, nachname, vorname, startzeit, zielzeit,
		   nennungseingang, start, start_morgen, geburtsdatum,
		   wohnort, club, fahrzeug, versicherung, land, bundesland,
		   lizenznummer, email, runden, ausfall
	    FROM fahrer
	    WHERE id = ?
	});
	$sth->execute($id);
	my $fahrer = {};
	while (my $row = $sth->fetchrow_hashref) {
	    fixup_hashref($sth, $row);
	    $row->{wertungen} = [];
	    my $startnummer = $row->{startnummer};
	    $fahrer->{$startnummer} = $row;
	}

	$sth = $dbh->prepare(qq{
	    SELECT startnummer, wertung
	    FROM fahrer_wertung
	    WHERE id = ?
	    ORDER BY startnummer, wertung
	});
	$sth->execute($id);
	while (my @row = $sth->fetchrow_array) {
	    fixup_arrayref($sth, \@row);
	    push @{$fahrer->{$row[0]}{wertungen}}, $row[1]
		if exists $fahrer->{$row[0]};
	}
	$dbh->commit;
	$result = [ values %$fahrer ];
    } elsif ($op eq "GET/veranstaltung/dump") {
	my ($tag) = parameter($q, qw(tag));
	$dbh->begin_work;
	my $id = veranstaltung_tag_to_id($dbh, $tag);
	$result = export($id)
	    if $id;
	$dbh->commit;
    } elsif ($op eq "OPTIONS/veranstaltung/patch") {
    } elsif ($op eq "POST/veranstaltung/patch") {
	my ($tag) = parameter($q, qw(tag));

	$dbh->begin_work;
	my $id = veranstaltung_tag_to_id($dbh, $tag);
	if (defined $id) {
	    my $data0 = export($id);
	    my $postdata = $q->param('POSTDATA');
	    _utf8_on($postdata);

	    print STDERR "Patch: $postdata\n"
		if $cgi_verbose;

	    my $patch = $json->decode($postdata);
	    my $patcher = JSON::Patch->new(operations => $patch);
	    my $ctx = $patcher->patch($data0);
	    if ($ctx->{result}) {
		my $data1 = $ctx->{document};
		importieren($data0, $data1, 1, 0);
	    } else {
		die HTTPError->new('409 Conflict', 'Patch fehlgeschlagen');
	    }
	} else {
	    die HTTPError('404 Not Found', 'Veranstaltung nicht gefunden');
	}
	$dbh->commit;
    } else {
	die HTTPError->new('404 Not Found', "Operation '$op' not defined");
    }
};
if ($@) {
    if ($@->isa('HTTPError')) {
	$headers->{status} = $@->{status};
	if ($headers->{'Content-Type'} eq 'application/json') {
	    $result = { error => $@->{error} };
	} else {
	    #$headers->{'Content-Type'} = 'text/plain';
	    $result = $@->{error};
	}
    } else {
	if ($@ =~ /Duplicate entry .* for key 'PRIMARY'/) {
	    $headers->{status} = '403 Duplicate Row';
	    $result = { error => $@ };
	} else {
	    print STDERR "$@\n";
	    $headers->{status} = '500 Internal Server Error';
	    $result = { error => $@ };
	}
    }
    $dbh->disconnect;
}

if ($headers->{'Content-Type'} eq 'application/json') {
    # Note: The result must be a list or an object to be valid JSON!
    $result = $result ? $json->encode($result) : '{}';
    $result = Encode::encode_utf8($result);
    $headers->{'Charset'} = 'utf-8';

    if (($ENV{HTTP_ACCEPT_ENCODING} // '') =~ /\bgzip\b/) {
	$headers->{'Content-Encoding'} = 'gzip';
	$result = Compress::Zlib::memGzip($result);
    }
}

# FIXME: Wenn der Client den Content-Type nicht akzeptiert (Header Accept),
# stattdessen Fehlercode liefern? (Die POST-Requests "akzeptieren" momentan
# application/json nicht.)

$headers->{'Content-Length'} = length($result);

print header($headers);
binmode STDOUT;
print $result;
