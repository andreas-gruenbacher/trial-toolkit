#! /usr/bin/perl -w -I../../trial-toolkit

use utf8;
use CGI qw(:cgi header);
#use CGI::Carp qw(warningsToBrowser fatalsToBrowser);
use CGI::Carp qw(fatalsToBrowser);
use Encode qw(_utf8_on);
use JSON;
use JSON_bool;
use DBI qw(:sql_types);
use Datenbank;
use DatenbankAktualisieren;
use TrialToolkit;
use strict;
#use Data::Dumper;

my $trace_sql = 1;

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

my @fahrer_nonkeys = qw(
    version klasse helfer bewerber nenngeld nachname vorname strasse wohnort
    plz club fahrzeug geburtsdatum telefon lizenznummer rahmennummer
    kennzeichen hubraum bemerkung bundesland land startzeit zielzeit
    nennungseingang papierabnahme versicherung zusatzpunkte punkte ausfall
    stechen runden);

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

sub get_veranstaltung($$) {
    my ($dbh, $id) = @_;
    my $result;

    # FIXME: Stattdessen cfg_aus_datenbank() verwenden!

    my $sth = $dbh->prepare(q{
	SELECT version, id, datum, dateiname, punkte_sektion_auslassen,
	       vierpunktewertung, wertung1_markiert, versicherung,
	       punkte_sektion_auslassen, wertungsmodus, wertungspunkte_234,
	       punkteteilung, wertung1_markiert, versicherung, aktiv
	FROM veranstaltung
	WHERE id = ?
    });
    $sth->execute($id);
    $result = $sth->fetchrow_hashref;
    fixup_hashref($sth, $result);
    if (%$result) {
	$sth = $dbh->prepare(q{
	    SELECT wertung, titel, subtitel, bezeichnung
	    FROM wertung
	    WHERE id = ?
	});
	$sth->execute($id);
	my $wertungen = [];
	while (my $row = $sth->fetchrow_hashref) {
	    fixup_hashref($sth, $row);
	    my $wertung = $row->{wertung};
	    delete $row->{wertung};
	    $wertungen->[$wertung - 1] = $row;
	}
	$result->{wertungen} = $wertungen;

	$sth = $dbh->prepare(q{
	    SELECT klasse, sektion
	    FROM sektion
	    WHERE id = ?
	    ORDER BY sektion
	});
	$sth->execute($id);
	my $sektionen = [];
	while (my @row = $sth->fetchrow_array) {
	    fixup_arrayref($sth, \@row);
	    push @{$sektionen->[$row[0] - 1]}, $row[1];
	}
	$result->{sektionen} = $sektionen;

	$sth = $dbh->prepare(q{
	    SELECT klasse, runden, fahrzeit, bezeichnung, farbe
	    FROM klasse
	    WHERE id = ?
	});
	$sth->execute($id);
	my $klassen = [];
	while (my $row = $sth->fetchrow_hashref) {
	    fixup_hashref($sth, $row);
	    my $klasse = $row->{klasse};
	    delete $row->{klasse};
	    $klassen->[$klasse - 1] = $row;
	}
	$result->{klassen} = $klassen;

	$sth = $dbh->prepare(q{
	    SELECT rang, punkte
	    FROM wertungspunkte
	    WHERE id = ?
	});
	$sth->execute($id);
	my $wertungspunkte = [];
	while (my @row = $sth->fetchrow_array) {
	    fixup_arrayref($sth, \@row);
	    $wertungspunkte->[$row[0] - 1] = $row[1];
	}
	$result->{wertungspunkte} = $wertungspunkte;

	$sth = $dbh->prepare(q{
	    SELECT runde, farbe
	    FROM kartenfarbe
	    WHERE id = ?
	});
	$sth->execute($id);
	my $kartenfarben = [];
	while (my @row = $sth->fetchrow_array) {
	    fixup_arrayref($sth, \@row);
	    $kartenfarben->[$row[0] - 1] = $row[1];
	}
	$result->{kartenfarben} = $kartenfarben;

	$sth = $dbh->prepare(q{
	    SELECT feature
	    FROM veranstaltung_feature
	    WHERE id = ?
	});
	$sth->execute($id);
	my $features = [];
	while (my @row = $sth->fetchrow_array) {
	    fixup_arrayref($sth, \@row);
	    push @$features, $row[0];
	}
	$result->{features} = $features;
    }
    return $result;
}

my $result;
my $status = '200 OK';
if ($op eq 'GET/vareihen') {
    my $sth = $dbh->prepare(q{
	SELECT vareihe, bezeichnung, verborgen
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
	SELECT id, datum, titel, aktiv
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
    $result = get_veranstaltung($dbh, $id);
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
    my $fahrer1 = from_json($putdata);

    print STDERR "$putdata\n";

    die "Ungültige Startnummer\n"
	if defined $fahrer1->{startnummer} &&
	   $fahrer1->{startnummer} !~ /^\d+$/;

    my $fahrer0;
    eval {
	$dbh->begin_work;
	if (defined $startnummer) {
	    my $fahrer_nach_startnummer =
		fahrer_aus_datenbank($dbh, $id, $startnummer);
	    $fahrer0 = $fahrer_nach_startnummer->{$startnummer};
	    die "Invalid Row Version\n"
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
	$dbh->commit;
    };
    if ($@) {
	print STDERR $@;
	if ($@ =~ /Invalid Row Version/) {
	    $status = '409 Conflict';
	} elsif ($@ =~ /Duplicate entry .* for key 'PRIMARY'/) {
	    $status = '403 Duplicate Row';
	} else {
	    $status = '500 Internal Server Error';
	}
	$result->{error} = $@;
	$dbh->disconnect;
    } else {
	$status = $fahrer0 ? '200 Modified' : '201 Created';
	$startnummer = $fahrer1->{startnummer};
	$result = get_fahrer($dbh, $id, $startnummer);
    }
} elsif ($op eq "PUT/veranstaltung") {
    my ($version) = parameter($q, qw(version));
    my $id = $q->url_param('id');  # Alte ID
    my $putdata = $q->param('PUTDATA');
    _utf8_on($putdata);
    my $cfg1 = from_json($putdata);

    print STDERR "$putdata\n";

    my $cfg0;
    my ($basis, $id_neu);
    if (defined $cfg1->{basis}) {
	$basis = $cfg1->{basis};
	delete $cfg1->{basis};
    }
    die "Sowohl 'basis' als auch 'id' definiert\n"
	if defined $basis && defined $id;

    eval {
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
	if (defined $basis) {
	    veranstaltung_duplizieren($do_sql, $basis, $id_neu);
	    $version = 1;
	}
	if (defined $id || defined $basis) {
	    $cfg0 = cfg_aus_datenbank($dbh, $id_neu);
	    die "Invalid Row Version\n"
		if $cfg0->{version} != $version;
	}
	veranstaltung_aktualisieren $do_sql, $id_neu, $cfg0, $cfg1;
	wertung_aktualisieren $dbh, $do_sql, $id_neu;
	$dbh->commit;
	$id = $id_neu;
    };
    if ($@) {
	print STDERR $@;
	if ($@ =~ /Invalid Row Version/) {
	    $status = '409 Conflict';
	} elsif ($@ =~ /Duplicate entry .* for key 'PRIMARY'/) {
	    $status = '403 Duplicate Row';
	} else {
	    $status = '500 Internal Server Error';
	}
	$result->{error} = $@;
	$dbh->disconnect;
    } else {
	$status = $cfg0 ? '200 Modified' : '201 Created';
	$result = get_veranstaltung($dbh, $id);
    }
} elsif ($op eq "PUT/vareihe") {
    my ($version) = parameter($q, qw(version));
    my $vareihe = $q->url_param('vareihe');  # Alte vareihe-ID
    my $putdata = $q->param('PUTDATA');
    _utf8_on($putdata);
    my $data1 = from_json($putdata);

    print STDERR "$putdata\n";

    my $data0;
    eval {
	$dbh->begin_work;

	if (defined $vareihe) {
	    $data0 = vareihe_aus_datenbank($dbh, $vareihe);
	    die "Invalid Row Version\n"
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
	vareihe_aktualisieren $do_sql, $vareihe, $data0, $data1;
	$dbh->commit;
    };
    if ($@) {
	print STDERR $@;
	if ($@ =~ /Invalid Row Version/) {
	    $status = '409 Conflict';
	} elsif ($@ =~ /Duplicate entry .* for key 'PRIMARY'/) {
	    $status = '403 Duplicate Row';
	} else {
	    $status = '500 Internal Server Error';
	}
	$result->{error} = $@;
	$dbh->disconnect;
    } else {
	$status = $data0 ? '200 Modified' : '201 Created';
	$result = vareihe_aus_datenbank($dbh, $vareihe);
    }
} elsif ($op eq "DELETE/fahrer") {
    my ($id, $version, $startnummer) = parameter($q, qw(id version startnummer));
    eval {
	$dbh->begin_work;
	my $sth = $dbh->prepare(qq{
	    DELETE FROM fahrer
	    WHERE id = ? AND startnummer = ? AND version = ?
	});
	if ($sth->execute($id, $startnummer, $version) != 1) {
	    die "Invalid Row Version\n";
	}
	foreach my $tabelle (qw(fahrer_wertung punkte runde neue_startnummer)) {
	    my $sth = $dbh->prepare(qq{
		DELETE FROM $tabelle
		WHERE id = ? AND startnummer = ?
	    });
	    $sth->execute($id, $startnummer);
	}
	wertung_aktualisieren $dbh, $do_sql, $id;
	$dbh->commit;
    };
    if ($@) {
	print STDERR $@;
	if ($@ =~ /Invalid Row Version/) {
	    $status = '409 Conflict';
	} else {
	    $status = '500 Internal Server Error';
	}
	$result->{error} = $@;
	$dbh->disconnect;
    } else {
	$status = '200 Deleted';
    }
} elsif ($op eq "DELETE/veranstaltung") {
    my ($id, $version) = parameter($q, qw(id version));
    eval {
	$dbh->begin_work;
	my $sth = $dbh->prepare(qq{
	    DELETE FROM veranstaltung
	    WHERE id = ? AND version = ?
	});
	if ($sth->execute($id, $version) != 1) {
	    die "Invalid Row Version\n";
	}
	foreach my $tabelle (qw(fahrer fahrer_wertung klasse punkte runde
				sektion veranstaltung_feature kartenfarbe
				wertung wertungspunkte neue_startnummer
				vareihe_veranstaltung)) {
	    my $sth = $dbh->prepare(qq{
		DELETE FROM $tabelle
		WHERE id = ?
	    });
	    $sth->execute($id);
	}
	$dbh->commit;
    };
    if ($@) {
	print STDERR $@;
	if ($@ =~ /Invalid Row Version/) {
	    $status = '409 Conflict';
	} else {
	    $status = '500 Internal Server Error';
	}
	$result->{error} = $@;
	$dbh->disconnect;
    } else {
	$status = '200 Deleted';
    }
} elsif ($op eq "DELETE/vareihe") {
    my ($vareihe, $version) = parameter($q, qw(vareihe version));
    eval {
	$dbh->begin_work;
	my $sth = $dbh->prepare(qq{
	    DELETE FROM vareihe
	    WHERE vareihe = ? AND version = ?
	});
	if ($sth->execute($vareihe, $version) != 1) {
	    die "Invalid Row Version\n";
	}
	foreach my $tabelle (qw(vareihe_veranstaltung vareihe_klasse)) {
	    my $sth = $dbh->prepare(qq{
		DELETE FROM $tabelle
		WHERE vareihe = ?
	    });
	    $sth->execute($vareihe);
	}
	$dbh->commit;
    };
    if ($@) {
	print STDERR $@;
	if ($@ =~ /Invalid Row Version/) {
	    $status = '409 Conflict';
	} else {
	    $status = '500 Internal Server Error';
	}
	$result->{error} = $@;
	$dbh->disconnect;
    } else {
	$status = '200 Deleted';
    }
} elsif ($op eq "GET/fahrer/suchen") {
    my ($id, $suchbegriff) = parameter($q, qw(id suchbegriff));
    my $select_fahrer = q{
	SELECT startnummer, nachname, vorname, geburtsdatum, klasse
	FROM fahrer
    };
    $result = [];
    if ($suchbegriff =~ /^\d+$/) {
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
	$suchbegriff =~ s/\s+/.* /g;
	$suchbegriff = "^$suchbegriff";

	my $sth = $dbh->prepare($select_fahrer . q{
	    WHERE id = ? AND
		  (CONCAT(COALESCE(vorname, ''), ' ', COALESCE(nachname, '')) REGEXP ? OR
		   CONCAT(COALESCE(nachname, ''), ' ', COALESCE(vorname, '')) REGEXP ?)
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
	$status = "404 Not Found";
	$result = { error => "Veranstaltungsreihe $vareihe nicht gefunden" };
    }
} else {
    $status = "404 Not Found";
    $result->{error} = "Operation '$op' not defined";
}

print header(-type => 'application/json', -charset => 'utf-8', -status => $status);
# Note: The result must be a list or an object to be valid JSON!
print $result ? to_json($result) : '{}';