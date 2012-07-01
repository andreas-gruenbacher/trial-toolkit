# Wertungen

# Copyright (C) 2012  Andreas Gruenbacher  <andreas.gruenbacher@gmail.com>
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later
# version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU Affero General Public License for more
# details.
#
# You can find a copy of the GNU Affero General Public License at
# <http://www.gnu.org/licenses/>.

package Wertungen;

require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw(rang_und_wertungspunkte_berechnen tageswertung jahreswertung max_time);

use utf8;
use List::Util qw(max);
use RenderOutput;
use Time::Local;
use strict;

my $klassenfarben = {
     1 => "red",
     2 => "blue",
     3 => "yellow",
     4 => "green",
     5 => "white",
     6 => "yellow",
     7 => "green",
    11 => "red",
    12 => "blue",
    13 => "yellow",
};

sub rang_vergleich($$$) {
    my ($a, $b, $cfg) = @_;

    if ($a->{ausfall} != $b->{ausfall}) {
	# Fahrer ohne Ausfall zuerst
	return $a->{ausfall} <=> $b->{ausfall}
	    if !$a->{ausfall} != !$b->{ausfall};
	# Danach Fahrer, die nicht aus der Wertung sind
	return ($a->{ausfall} == 4) <=> ($b->{ausfall} == 4)
	    if $a->{ausfall} == 4 || $b->{ausfall} == 4;
    }

    # Abfallend nach gefahrenen Runden
    return $b->{runden} <=> $a->{runden}
	if $a->{runden} != $b->{runden};

    # Aufsteigend nach Punkten
    return $a->{punkte} <=> $b->{punkte}
	if $a->{punkte} != $b->{punkte};

    # Aufsteigend nach Ergebnis im Stechen
    return $a->{stechen} <=> $b->{stechen}
	if  $a->{stechen} != $b->{stechen};

    # Abfallend nach 0ern, 1ern, 2ern, 3ern
    for (my $n = 0; $n < 4; $n++) {
	return $b->{"s$n"} <=> $a->{"s$n"}
	    if $a->{"s$n"} != $b->{"s$n"};
    }

    # Aufsteigend nach der besten Runde?
    if ($cfg->{wertungsmodus} != 0) {
	my $ax = $a->{punkte_pro_runde};
	my $bx = $b->{punkte_pro_runde};
	if ($cfg->{wertungsmodus} == 1) {
	    for (my $n = 0; $n < @$ax; $n++) {
		return $ax->[$n] <=> $bx->[$n]
		    if $ax->[$n] != $bx->[$n];
	    }
	} else {
	    for (my $n = @$ax - 1; $n >= 0; $n--){
		return $ax->[$n] <=> $bx->[$n]
		    if $ax->[$n] != $bx->[$n];
	    }
	}
    }

    # Identische Wertung
    return 0;
}

sub rang_und_wertungspunkte_berechnen($$) {
    my ($fahrer_nach_startnummer, $cfg) = @_;
    my $wertungspunkte = $cfg->{wertungspunkte};

    my $fahrer_nach_klassen = fahrer_nach_klassen($fahrer_nach_startnummer);
    foreach my $klasse (keys %$fahrer_nach_klassen) {
	my $fahrer_in_klasse = $fahrer_nach_klassen->{$klasse};

	my $rang = 1;
	$fahrer_in_klasse = [ sort { rang_vergleich($a, $b, $cfg) } @$fahrer_in_klasse ];
	$fahrer_in_klasse = [ map { ($_->{runden} > 0 ||
				     $_->{papierabnahme}) ?
				     $_ : () } @$fahrer_in_klasse ];
	my $vorheriger_fahrer;
	foreach my $fahrer (@$fahrer_in_klasse) {
	    $fahrer->{rang} =
		$vorheriger_fahrer &&
		rang_vergleich($vorheriger_fahrer, $fahrer, $cfg) == 0 ?
		    $vorheriger_fahrer->{rang} : $rang;
	    $rang++;
	    $vorheriger_fahrer = $fahrer;
	}
	$fahrer_nach_klassen->{$klasse} = $fahrer_in_klasse;
    }

    for (my $wertung = 0; $wertung < @{$cfg->{wertungen}}; $wertung++) {
	foreach my $klasse (keys %$fahrer_nach_klassen) {
	    my $fahrer_in_klasse = $fahrer_nach_klassen->{$klasse};

	    my $wp_idx = 0;
	    my $vorheriger_fahrer;
	    foreach my $fahrer (@$fahrer_in_klasse) {
		next unless defined $fahrer->{rang} &&
			    $fahrer->{wertungen}[$wertung] &&
			    !$fahrer->{ausfall};
		if ($vorheriger_fahrer &&
		    $vorheriger_fahrer->{rang} == $fahrer->{rang}) {
		    $fahrer->{wertungspunkte}[$wertung] =
			$vorheriger_fahrer->{wertungspunkte}[$wertung];
		} elsif ($wp_idx < @$wertungspunkte &&
			 $wertungspunkte->[$wp_idx] != 0) {
		    $fahrer->{wertungspunkte}[$wertung] = $wertungspunkte->[$wp_idx];
		}
		$wp_idx++;
		$vorheriger_fahrer = $fahrer;
	    }
	    foreach my $fahrer (@$fahrer_in_klasse) {
		$fahrer->{wertungspunkte}[$wertung] = undef
		    if $fahrer->{keine_wertungspunkte};
	    }
	}
    }
}

sub fahrer_nach_klassen($) {
    my ($fahrer_nach_startnummern) = @_;
    my $fahrer_nach_klassen;

    foreach my $fahrer (values %$fahrer_nach_startnummern) {
	my $klasse = $fahrer->{klasse};
	push @{$fahrer_nach_klassen->{$klasse}}, $fahrer;
    }
    return $fahrer_nach_klassen;
}

sub rang_wenn_definiert($$) {
    my ($a, $b) = @_;

    return exists($b->{rang}) - exists($a->{rang})
	if !exists($a->{rang}) || !exists($b->{rang});
    return $a->{rang} <=> $b->{rang}
	if $a->{rang} != $b->{rang};
    return $a->{startnummer} <=> $b->{startnummer};
}

sub spaltentitel($) {
    my ($feld) = @_;

    my $titel = {
	"geburtsdatum" => "Geb.datum",
	"lizenznummer" => "Lizenz",
    };
    if (exists $titel->{$feld}) {
	return $titel->{$feld};
    } else {
	return ucfirst $feld;
    }
}

sub tageswertung($$$$$) {
    my ($cfg, $fahrer_nach_startnummer, $wertung, $spalten, $alle_punkte) = @_;

    my $ausfall = {
	3 => "ausgefallen",
	4 => "aus der wertung",
	5 => "nicht gestartet",
	6 => "nicht gestartet, entschuldigt"
    };

    # Wir wollen, dass alle Tabellen gleich breit sind.
    my $namenlaenge = 0;
    foreach my $fahrer (values %$fahrer_nach_startnummer) {
	my $n = length "$fahrer->{nachname}, $fahrer->{vorname}";
	$namenlaenge = max($n, $namenlaenge);
    }

    my $zusatzpunkte;
    my $vierer;
    foreach my $fahrer (values %$fahrer_nach_startnummer) {
	$vierer = 1
	    if $fahrer->{s4};
	$zusatzpunkte = 1
	    if $fahrer->{zusatzpunkte};
    }

    my $fahrer_nach_klassen = fahrer_nach_klassen($fahrer_nach_startnummer);
    foreach my $klasse (sort {$a <=> $b} keys %$fahrer_nach_klassen) {
	my $fahrer_in_klasse = $fahrer_nach_klassen->{$klasse};
	my $idx = $klasse - 1;
	my $runden = $cfg->{runden}[$idx];
	my ($header, $body, $format);
	my $farbe = "";

	$fahrer_in_klasse = [ map { ($_->{runden} > 0 ||
				     $_->{papierabnahme}) ?
				     $_ : () } @$fahrer_in_klasse ];
	next unless @$fahrer_in_klasse > 0;

	my $wertungspunkte;
	foreach my $fahrer (values @$fahrer_in_klasse) {
	    $wertungspunkte = 1
		if defined $fahrer->{wertungspunkte}[$wertung];
	}

	my $ausfall_fmt = "c" . ($vierer ? 6 : 5);

	if ($RenderOutput::html && exists $klassenfarben->{$klasse}) {
	    $farbe = "<font color=\"$klassenfarben->{$klasse}\">◼</font>";
	}

	doc_h3 "$cfg->{klassen}[$idx]";
	push @$format, "r3", "r3", "l$namenlaenge";
	push @$header, [ "$farbe", "c" ], [ "Nr.", "r1", "title=\"Startnummer\"" ], "Name";
	foreach my $spalte (@$spalten) {
	    push @$format, "l";
	    push @$header, spaltentitel($spalte);
	}
	for (my $n = 0; $n < $runden; $n++) {
	    push @$format, "r2";
	    push @$header, [ "R" . ($n + 1), "r1", "title=\"Runde " . ($n + 1) . "\"" ];
	}
	if ($zusatzpunkte) {
	    push @$format, "r2";
	    push @$header, [ "ZP", "r1", "title=\"Zeit- und Zusatzpunkte\"" ];
	}
	push @$format, "r2", "r2", "r2", "r2";
	push @$header, [ "0S", "r1", "title=\"Nuller\"" ];
	push @$header, [ "1S", "r1", "title=\"Einser\"" ];
	push @$header, [ "2S", "r1", "title=\"Zweier\"" ];
	push @$header, [ "3S", "r1", "title=\"Dreier\"" ];
	if ($vierer) {
	    push @$format, "r2";
	    push @$header, [ "4S", "r1", "title=\"Vierer\"" ];
	}
	push @$format, "r3", "r2";
	push @$header, [ "Ges", "r1", "title=\"Gesamtpunkte\"" ];
	push @$header, [ "WP", "r1", "title=\"Wertungspunkte\"" ]
	    if $wertungspunkte;

	$fahrer_in_klasse = [ sort rang_wenn_definiert @$fahrer_in_klasse ];
	foreach my $fahrer (@$fahrer_in_klasse) {
	    my $row;
	    if (!$fahrer->{ausfall}) {
		push @$row, "$fahrer->{rang}.";
	    } else {
		push @$row, "";
	    }
	    push @$row, $fahrer->{startnummer};
	    push @$row, $fahrer->{nachname} . ", " . $fahrer->{vorname};
	    foreach my $spalte (@$spalten) {
		push @$row, defined $fahrer->{$spalte} ?
			    $fahrer->{$spalte} : "";
	    }
	    for (my $n = 0; $n < $runden; $n++) {
		if ($fahrer->{runden} > $n) {
		    if ($alle_punkte) {
			my $punkte_pro_runde = $fahrer->{punkte_pro_sektion}[$n];
			my $punkte;
			for (my $s = 0; $s < @$punkte_pro_runde; $s++) {
			    if (substr($cfg->{sektionen}[$klasse - 1], $s, 1) eq "J") {
				push @$punkte, $punkte_pro_runde->[$s];
			    }
			}
			$punkte = join(" ", @$punkte);
			push @$row, [ $fahrer->{punkte_pro_runde}[$n], "r1",
				      "title=\"$punkte\"" ];
		    } else {
			push @$row, $fahrer->{punkte_pro_runde}[$n];
		    }
		} elsif ($fahrer->{ausfall} == 0 || $fahrer->{ausfall} == 4) {
		    push @$row, undef;
		} else {
		    push @$row, "-";
		}
	    }
	    push @$row, $fahrer->{zusatzpunkte} || ""
		if $zusatzpunkte;

	    if ($fahrer->{ausfall} != 0) {
		push @$row, [ $ausfall->{$fahrer->{ausfall}}, $ausfall_fmt ];
	    } elsif ($fahrer->{runden} == 0) {
		push @$row, [ "", $ausfall_fmt ];
	    } else {
		for (my $n = 0; $n < ($vierer ? 5 : 4); $n++) {
		    push @$row, $fahrer->{"s$n"};
		}
		push @$row, $fahrer->{punkte} || "";
	    }
	    push @$row, $fahrer->{wertungspunkte}[$wertung] || ""
		if $wertungspunkte;
	    push @$body, $row;
	}
	doc_table $header, $body, undef, $format;
    }
}

sub jahreswertung_berechnen($$) {
    my ($jahreswertung, $streichgrenze) = @_;

    foreach my $klasse (keys %$jahreswertung) {
	foreach my $startnummer (keys %{$jahreswertung->{$klasse}}) {
	    my $fahrer = $jahreswertung->{$klasse}{$startnummer};
	    $jahreswertung->{$klasse}{$startnummer}{startnummer} = $startnummer;
	    my $wertungspunkte = $fahrer->{wertungspunkte};
	    my $n = 0;
	    if (defined $streichgrenze) {
		my $streichresultate = @$wertungspunkte - $streichgrenze;
		if ($streichresultate > 0) {
		    $fahrer->{streichpunkte} = 0;
		    $wertungspunkte = [ sort { $a <=> $b }
					     @$wertungspunkte ];
		    for (; $n < $streichresultate; $n++) {
			$fahrer->{streichpunkte} += $wertungspunkte->[$n];
		    }
		}
	    }
	    $fahrer->{gesamtpunkte} = 0;
	    for (; $n < @$wertungspunkte; $n++) {
		$fahrer->{gesamtpunkte} += $wertungspunkte->[$n];
	    }
	}
    }
}

sub jahreswertung_cmp {
    return $b->{gesamtpunkte} <=> $a->{gesamtpunkte}
	if $a->{gesamtpunkte} != $b->{gesamtpunkte};
    return $b->{streichpunkte} <=> $a->{streichpunkte}
	if exists $a->{streichpunkte} &&
	   exists $b->{streichpunkte} &&
	   $a->{streichpunkte} != $b->{streichpunkte};
    return $a->{startnummer} <=> $b->{startnummer};
}

sub jahreswertung($$$$) {
    my ($veranstaltungen, $wertung, $streichgrenze, $spalten) = @_;

    my $veranstaltungen_pro_klasse;
    foreach my $veranstaltung (@$veranstaltungen) {
	my $cfg = $veranstaltung->[0];
	foreach my $fahrer (values %{$veranstaltung->[1]}) {
	    $cfg->{gewertet}[$fahrer->{klasse} - 1] = 1
		if defined $fahrer->{wertungspunkte}[$wertung];
	}
	if (exists $cfg->{gewertet}) {
	    for (my $n = 0; $n < @{$cfg->{gewertet}}; $n++) {
		$veranstaltungen_pro_klasse->{$n + 1}++
		    if defined $cfg->{gewertet}[$n];
	    }
	}
    }

    my $spaltenbreite = 2;
    #foreach my $veranstaltung (@$veranstaltungen) {
    #	my $cfg = $veranstaltung->[0];
    #	my $l = length $cfg->{label};
    #	$spaltenbreite = $l
    #	    if $l > $spaltenbreite;
    #}

    my $alle_fahrer;

    my $jahreswertung;
    foreach my $veranstaltung (@$veranstaltungen) {
	my $fahrer_nach_startnummer = $veranstaltung->[1];

	foreach my $fahrer (values %$fahrer_nach_startnummer) {
	    my $startnummer = $fahrer->{startnummer};
	    if (defined $fahrer->{wertungspunkte}[$wertung]) {
		my $klasse = $fahrer->{klasse};
		push @{$jahreswertung->{$klasse}{$startnummer}{wertungspunkte}},
		    $fahrer->{wertungspunkte}[$wertung];
	    }
	    $alle_fahrer->{$startnummer} = $fahrer;
	}
    }

    my $letzte_cfg = $veranstaltungen->[@$veranstaltungen - 1][0];

    jahreswertung_berechnen $jahreswertung, $streichgrenze;

    # Wir wollen, dass alle Tabellen gleich breit sind.
    my $namenlaenge = 0;
    foreach my $fahrer (map { $alle_fahrer->{$_} }
			    map { keys %$_ } values %$jahreswertung) {
	my $n = length "$fahrer->{nachname}, $fahrer->{vorname}";
	$namenlaenge = max($n, $namenlaenge);
    }

    foreach my $klasse (sort {$a <=> $b} keys %$jahreswertung) {
	my $streichresultate = defined $streichgrenze ?
	    $veranstaltungen_pro_klasse->{$klasse} - $streichgrenze : 0;
	my $klassenwertung = $jahreswertung->{$klasse};
	if ($streichresultate > 0) {
	    if ($streichresultate == 1) {
		doc_h3 "$letzte_cfg->{klassen}[$klasse - 1] (1 Streichresultat)";
	    } else {
		doc_h3 "$letzte_cfg->{klassen}[$klasse - 1] ($streichresultate Streichresultate)";
	    }
	} else {
	    doc_h3 "$letzte_cfg->{klassen}[$klasse - 1]";
	}
	my ($header, $body, $format);
	my $farbe = "";
	if ($RenderOutput::html && exists $klassenfarben->{$klasse}) {
	    $farbe = "<font color=\"$klassenfarben->{$klasse}\">◼</font>";
	}
	push @$format, "r3", "r3", "l$namenlaenge";
	push @$header, [ $farbe, "c" ], [ "Nr.", "r1", "title=\"Startnummer\"" ], "Name";
	foreach my $spalte (@$spalten) {
	    push @$format, "l";
	    push @$header, spaltentitel($spalte);
	}
	for (my $n = 0; $n < @$veranstaltungen; $n++) {
	    my $cfg = $veranstaltungen->[$n][0];
	    my $gewertet = $cfg->{gewertet}[$klasse - 1];
	    if ($gewertet) {
		push @$format, "r$spaltenbreite";
		push @$header,  $gewertet ? [ $cfg->{label}, "r1", "title=\"$cfg->{titel}[$wertung]\"" ] : "";
	    }
	}
	if ($streichresultate > 0) {
	    push @$format, "r3";
	    push @$header, [ "Str", "r1", "title=\"Gestrichene Punkte\"" ];
	}
	push @$format, "r3";
	push @$header, [ "Ges", "r1", "title=\"Gesamtpunkte\"" ];

	my $fahrer_in_klasse = [
	    map { $alle_fahrer->{$_->{startnummer}} }
		(sort jahreswertung_cmp (values %$klassenwertung)) ];

	my $letzter_fahrer;
	for (my $n = 0; $n < @$fahrer_in_klasse; $n++) {
	    my $fahrer = $fahrer_in_klasse->[$n];
	    my $startnummer = $fahrer->{startnummer};

	    if ($letzter_fahrer &&
		$klassenwertung->{$startnummer}{gesamtpunkte} ==
		$klassenwertung->{$letzter_fahrer->{startnummer}}->{gesamtpunkte}) {
		$klassenwertung->{$startnummer}{rang} =
		    $klassenwertung->{$letzter_fahrer->{startnummer}}->{rang};
	    } else {
		$klassenwertung->{$startnummer}{rang} = $n + 1;
	    }
	    $letzter_fahrer = $fahrer;
	}

	foreach my $fahrer (@$fahrer_in_klasse) {
	    my $startnummer = $fahrer->{startnummer};
	    my $fahrerwertung = $klassenwertung->{$startnummer};
	    my $gesamtpunkte = $fahrerwertung->{gesamtpunkte};
	    my $row;
	    push @$row, $gesamtpunkte ? "$fahrerwertung->{rang}." : "";
	    push @$row, $startnummer,
			$alle_fahrer->{$startnummer}{nachname} . ", " .
			$alle_fahrer->{$startnummer}{vorname};
	    foreach my $spalte (@$spalten) {
		push @$row, defined $fahrer->{$spalte} ?
			    $fahrer->{$spalte} : "";
	    }
	    for (my $n = 0; $n < @$veranstaltungen; $n++) {
		my $veranstaltung = $veranstaltungen->[$n];
		my $gewertet = $veranstaltung->[0]{gewertet}[$klasse - 1];
		my $fahrer = $veranstaltung->[1]{$startnummer};
		if ($gewertet) {
		    push @$row, (defined $fahrer->{wertungspunkte}[$wertung] &&
				 $fahrer->{klasse} == $klasse) ?
				$fahrer->{wertungspunkte}[$wertung] :
				$RenderOutput::html ? "" : "-";
		}
	    }
	    push @$row, $fahrerwertung->{streichpunkte}
		if $streichresultate > 0;
	    push @$row, $gesamtpunkte != 0 ? $gesamtpunkte : "";
	    push @$body, $row;
	}
	doc_table $header, $body, undef, $format;
    }

    doc_h3 "Veranstaltungen:";
    my $body;
    for (my $n = 0; $n < @$veranstaltungen; $n++) {
	my $cfg = $veranstaltungen->[$n][0];
	my $label = defined $cfg->{label2} ? $cfg->{label2} : $cfg->{label};

	#push @$body, [ $label, "$cfg->{titel}[$wertung]: $cfg->{subtitel}[$wertung]" ];
	push @$body, [ $label, $cfg->{titel}[$wertung] ];
    }
    doc_table ["", "Name"], $body, undef, ["r", "l"];
}

sub max_time($$) {
    my ($a, $b) = @_;
    my ($ta, $tb);

    return $b unless defined $a;
    return $a unless defined $b;

    $ta = timelocal($6, $5, $4, $3, $2 - 1, $1 - 1900)
	if $a =~ /^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/;
    $tb = timelocal($6, $5, $4, $3, $2 - 1, $1 - 1900)
	if $b =~ /^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/;
    return $ta < $tb ? $b : $a;
}

1;
