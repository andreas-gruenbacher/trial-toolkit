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
@EXPORT = qw(rang_und_wertungspunkte_berechnen tageswertung jahreswertung);

use utf8;
use List::Util qw(min max);
use POSIX qw(modf);
use RenderOutput;
use Auswertung;
use strict;

sub wertungsklassen_setzen($$) {
    my ($fahrer_nach_startnummer, $cfg) = @_;
    my $klassen = $cfg->{klassen};

    foreach my $fahrer (values %$fahrer_nach_startnummer) {
	my $klasse = $fahrer->{klasse};
	my $wertungsklasse;
	$wertungsklasse = $klassen->[$klasse - 1]{wertungsklasse}
	  if defined $klasse;
	$fahrer->{wertungsklasse} = $wertungsklasse;
    }
}

sub rang_vergleich($$$) {
    my ($a, $b, $cfg) = @_;

    if (($a->{ausser_konkurrenz} // 0) != ($b->{ausser_konkurrenz} // 0)) {
	return $a->{ausser_konkurrenz} <=> $b->{ausser_konkurrenz};
    }

    if ($a->{ausfall} != $b->{ausfall}) {
	# Fahrer ohne Ausfall zuerst
	return $a->{ausfall} <=> $b->{ausfall}
	    if !$a->{ausfall} != !$b->{ausfall};
	# Danach Fahrer, die nicht aus der Wertung sind
	return ($a->{ausfall} == 4) <=> ($b->{ausfall} == 4)
	    if ($a->{ausfall} == 4) != ($b->{ausfall} == 4);
    }

    # Abfallend nach gefahrenen Sektionen: dadurch werden die Fahrer auf dann
    # richtig gereiht, wenn die Punkte sektionsweise statt rundenweise
    # eingegeben werden.
    return $b->{gefahrene_sektionen} <=> $a->{gefahrene_sektionen}
	if $a->{gefahrene_sektionen} != $b->{gefahrene_sektionen};

    # Aufsteigend nach Punkten
    return $a->{punkte} <=> $b->{punkte}
	if $a->{punkte} != $b->{punkte};

    # Aufsteigend nach Ergebnis im Stechen
    return $a->{stechen} <=> $b->{stechen}
	if  $a->{stechen} != $b->{stechen};

    # Abfallend nach 0ern, 1ern, 2ern, 3ern, 4ern
    for (my $n = 0; $n < 5; $n++) {
	return $b->{punkteverteilung}[$n] <=> $a->{punkteverteilung}[$n]
	    if $a->{punkteverteilung}[$n] != $b->{punkteverteilung}[$n];
    }

    # Aufsteigend nach der besten Runde?
    if ($cfg->{wertungsmodus} != 0) {
	my $ax = $a->{punkte_pro_runde} // [];
	my $bx = $b->{punkte_pro_runde} // [];
	if ($cfg->{wertungsmodus} == 1) {
	    for (my $n = 0; $n < @$ax; $n++) {
		last unless defined $ax->[$n];
		# Beide müssen definiert sein
		return $ax->[$n] <=> $bx->[$n]
		    if $ax->[$n] != $bx->[$n];
	    }
	} else {
	    for (my $n = @$ax - 1; $n >= 0; $n--){
		next unless defined $ax->[$n];
		# Beide müssen definiert sein
		return $ax->[$n] <=> $bx->[$n]
		    if $ax->[$n] != $bx->[$n];
	    }
	}
    }

    # Identische Wertung
    return 0;
}

sub hat_wertung($$) {
    my ($cfg, $wertung) = @_;

    grep(/^wertung$wertung$/, @{$cfg->{features}});
}

# Ermitteln, welche Klassen in welchen Sektionen und Runden überhaupt gefahren
# sind: wenn eine Klasse eine Sektion und Runde befahren hat, kann die Sektion
# und Runde nicht aus der Wertung sein, und alle Fahrer dieser Klasse müssen
# diese Sektion befahren.  Wenn eine Sektion nicht oder noch nicht befahren
# wurde, hat sie auch keinen Einfluss auf das Ergebnis.
sub befahrene_sektionen($) {
    my ($fahrer_nach_startnummer) = @_;
    my $befahren;

    foreach my $fahrer (values %$fahrer_nach_startnummer) {
	my $klasse = $fahrer->{wertungsklasse};
	if (defined $klasse && $fahrer->{start}) {
	    my $punkte_pro_sektion = $fahrer->{punkte_pro_sektion} // [];
	    for (my $runde = 0; $runde < @$punkte_pro_sektion; $runde++) {
		my $punkte = $punkte_pro_sektion->[$runde] // [];
		for (my $sektion = 0; $sektion < @$punkte; $sektion++) {
		    $befahren->[$klasse - 1][$runde][$sektion]++
			if defined $punkte->[$sektion];
		}
	    }
	}
    }
    return $befahren;
}

sub punkte_berechnen($$) {
    my ($fahrer_nach_startnummer, $cfg) = @_;
    my $befahren;

    # Das Trialtool erlaubt es, Sektionen in der Punkte-Eingabemaske
    # auszulassen.  Die ausgelassenen Sektionen sind danach "leer" (in den
    # Trialtool-Dateien wird der Wert 6 verwendet, in Perl übersetzen wir das
    # auf undef, und in der Datenbank verwenden wir NULL).  Für die
    # Punkteanzahl des Fahrers zählen diese Sektionen wie ein 0er, was zu einer
    # falschen Bewertung führt.  Für den Anwender ist es schwer, dieses Problem
    # zu erkennen und zu finden.
    #
    # Leider wird derselbe Wert auch für Sektionen verwendet, die (für eine
    # bestimmte Klasse und Runde) aus der Wertung genommen werden.  In diesem
    # Fall soll die Sektion ignoriert werden.
    #
    # Um diese Situation besser zu behandeln, überprüfen wir wenn wir eine
    # "leere" Sektion finden, ob die Sektion für alle anderen Fahrer auch
    # "leer" ist.  Das ist dann der Fall, wenn die Sektion noch nicht befahren
    # oder aus der Wertung genommen wurde; in beiden Fällen können wir die
    # Sektion ignorieren.  Wenn die Sektion für andere Fahrer nicht "leer" ist,
    # muss sie offensichtlich befahren werden, und wir dürfen sie nicht
    # ignorieren.
    #
    # Wenn die Daten nicht vom Trialtool stammen, merken wir uns explizit,
    # welche Sektionen aus der Wertung genommen wurden (sektionen_us_wertung).
    # Wir wissen dann genau, welche Sektionen ein Fahrer noch fahren muss.
    #
    # In jedem Fall werden die Fahrer zuerst nach der Anzahl der gefahrenen
    # Sektionen gereiht (bis zur ersten nicht erfassten Sektion, die befahren
    # werden muss), und erst danach nach den erzielten Punkten.  Das ergibt
    # auch eine brauchbare Zwischenwertung, wenn die Ergebnisse Sektion für
    # Sektion statt Runde für Runde eingegeben werden.

    my $sektionen_aus_wertung;
    if ($cfg->{sektionen_aus_wertung}) {
	$sektionen_aus_wertung = [];
	for (my $klasse_idx = 0; $klasse_idx < @{$cfg->{sektionen_aus_wertung}}; $klasse_idx++) {
	    my $runden = $cfg->{sektionen_aus_wertung}[$klasse_idx]
		or next;
	    for (my $runde_idx = 0; $runde_idx < @$runden; $runde_idx++) {
		my $sektionen = $runden->[$runde_idx];
		foreach my $sektion (@$sektionen) {
		    $sektionen_aus_wertung->[$klasse_idx][$runde_idx][$sektion - 1] = 1;
		}
	    }
	}
    }

    foreach my $fahrer (values %$fahrer_nach_startnummer) {
	my $punkte_pro_runde;
	my $gesamtpunkte;
	my $punkteverteilung;  # 0er, 1er, 2er, 3er, 4er, 5er
	my $gefahrene_sektionen;
	my $sektion_ausgelassen;
	my $letzte_begonnene_runde;
	my $letzte_vollstaendige_runde;

	my $klasse = $fahrer->{wertungsklasse};
	if (defined $klasse && $fahrer->{start}) {
	    my $punkte_pro_sektion = $fahrer->{punkte_pro_sektion} // [];
	    $gesamtpunkte = $fahrer->{zusatzpunkte};
	    $punkteverteilung = [(0) x 6];
	    $gefahrene_sektionen = 0;

	    my $sektionen = $cfg->{sektionen}[$klasse - 1] // [];

	    my $auslassen = $cfg->{punkte_sektion_auslassen};
	    my $runden = $cfg->{klassen}[$klasse - 1]{runden};
	    runde: for (my $runde = 1; $runde <= $runden; $runde++) {
		my $punkte_in_runde = $punkte_pro_sektion->[$runde - 1] // [];
		foreach my $sektion (@$sektionen) {
		    next if $sektionen_aus_wertung &&
			$sektionen_aus_wertung->[$klasse - 1][$runde - 1][$sektion - 1];
		    my $p = $punkte_in_runde->[$sektion - 1];
		    if (defined $p) {
			unless ($sektion_ausgelassen) {
			    $gefahrene_sektionen++;
			    $punkte_pro_runde->[$runde - 1] += $p == -1 ? $auslassen : $p;
			    $punkteverteilung->[$p]++
				if $p >= 0 && $p <= 5;
			    $letzte_begonnene_runde = $runde;
			}
		    } elsif ($sektionen_aus_wertung) {
			$sektion_ausgelassen = 1;
			$letzte_vollstaendige_runde = $runde - 1
			    unless defined $letzte_vollstaendige_runde;
		    } else {
			$letzte_vollstaendige_runde = $runde - 1
			    unless defined $letzte_vollstaendige_runde;
			$befahren = befahrene_sektionen($fahrer_nach_startnummer)
			    unless defined $befahren;
			$sektion_ausgelassen = 1
			    if defined $befahren->[$klasse - 1][$runde - 1][$sektion - 1];
		    }
		}
	    }
	    foreach my $punkte (@$punkte_pro_runde) {
		$gesamtpunkte += $punkte;
	    }
	    $letzte_begonnene_runde //= 0;
	    $letzte_vollstaendige_runde = $runden
		unless defined $letzte_vollstaendige_runde;
	    if ($letzte_begonnene_runde != $letzte_vollstaendige_runde) {
		print STDERR "Warnung: Ergebnisse von Fahrer $fahrer->{startnummer} " .
			     "in Runde $letzte_begonnene_runde sind unvollständig!\n";
	    }
	}

	$fahrer->{runden} = $letzte_begonnene_runde;
	$fahrer->{punkte} = $gesamtpunkte;
	$fahrer->{punkte_pro_runde} = $punkte_pro_runde;
	$fahrer->{punkteverteilung} = $punkteverteilung;
	$fahrer->{gefahrene_sektionen} = $gefahrene_sektionen;
    }
}

sub rang_und_wertungspunkte_berechnen($$) {
    my ($fahrer_nach_startnummer, $cfg) = @_;
    my $wertungspunkte = $cfg->{wertungspunkte};
    unless (@$wertungspunkte) {
	$wertungspunkte = [0];
    }

    wertungsklassen_setzen $fahrer_nach_startnummer, $cfg;

    punkte_berechnen $fahrer_nach_startnummer, $cfg;

    my $fahrer_nach_klassen = fahrer_nach_klassen($fahrer_nach_startnummer);

    foreach my $klasse (keys %$fahrer_nach_klassen) {
	my $fahrer_in_klasse = $fahrer_nach_klassen->{$klasse};

	# $fahrer->{rang} ist der Rang in der Tages-Gesamtwertung, in der alle
	# Starter aufscheinen.

	my $rang = 1;
	$fahrer_in_klasse = [
	    sort { rang_vergleich($a, $b, $cfg) }
		 map { $_->{start} ? $_ : () } @$fahrer_in_klasse ];
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

    foreach my $fahrer (values %$fahrer_nach_startnummer) {
	foreach my $wertung (@{$fahrer->{wertungen}}) {
	    if (defined $wertung) {
		delete $wertung->{rang};
		delete $wertung->{punkte};
	    }
	}
    }

    for (my $wertung = 1; $wertung <= 4; $wertung++) {
	next unless hat_wertung($cfg, $wertung);

	my $wertungspunkte_vergeben =
	    $wertung == 1 || $cfg->{wertungspunkte_234};

	foreach my $klasse (keys %$fahrer_nach_klassen) {
	    my $runden = $cfg->{klassen}[$klasse - 1]{runden};
	    my $fahrer_in_klasse = $fahrer_nach_klassen->{$klasse};

	    # $fahrer->{wertungen}[]{rang} ist der Rang in der jeweiligen
	    # Teilwertung.

	    my $rang = 1;
	    my $vorheriger_fahrer;
	    foreach my $fahrer (@$fahrer_in_klasse) {
		my $keine_wertung1 =
		  $cfg->{klassen}[$fahrer->{klasse} - 1]{keine_wertung1};
		next unless defined $fahrer->{rang} &&
			    $fahrer->{wertungen}[$wertung - 1]{aktiv} &&
			    ($wertung > 1 || !$keine_wertung1);
		if ($vorheriger_fahrer &&
		    $vorheriger_fahrer->{rang} == $fahrer->{rang}) {
		    $fahrer->{wertungen}[$wertung - 1]{rang} =
			$vorheriger_fahrer->{wertungen}[$wertung - 1]{rang};
		} else {
		    $fahrer->{wertungen}[$wertung - 1]{rang} = $rang;
		}
		$rang++;

		$vorheriger_fahrer = $fahrer;
	    }
	    if ($wertungspunkte_vergeben) {
		if ($cfg->{punkteteilung}) {
		    my ($m, $n);
		    for ($m = 0; $m < @$fahrer_in_klasse; $m = $n) {
			my $fahrer_m = $fahrer_in_klasse->[$m];
			if ($fahrer_m->{ausser_konkurrenz} ||
			    $fahrer_m->{ausfall} ||
			    $fahrer_m->{runden} < $runden ||
			    !defined $fahrer_m->{wertungen}[$wertung - 1]{rang}) {
			    $n = $m + 1;
			    next;
			}

			my $anzahl_fahrer = 1;
			for ($n = $m + 1; $n < @$fahrer_in_klasse; $n++) {
			    my $fahrer_n = $fahrer_in_klasse->[$n];
			    next if $fahrer_n->{ausser_konkurrenz} ||
				    $fahrer_n->{ausfall} ||
				    !defined $fahrer_n->{wertungen}[$wertung - 1]{rang};
			    last if $fahrer_m->{wertungen}[$wertung - 1]{rang} !=
				    $fahrer_n->{wertungen}[$wertung - 1]{rang};
			    $anzahl_fahrer++;
			}
			my $summe;
			my $wr = $fahrer_m->{wertungen}[$wertung - 1]{rang};
			for (my $i = 0; $i < $anzahl_fahrer; $i++) {
			    my $x = min($wr + $i, scalar @$wertungspunkte);
			    $summe += $wertungspunkte->[$x - 1];
			}
			for ($n = $m; $n < @$fahrer_in_klasse; $n++) {
			    my $fahrer_n = $fahrer_in_klasse->[$n];
			    next if $fahrer_n->{ausser_konkurrenz} ||
				    $fahrer_n->{ausfall} ||
				    !defined $fahrer_n->{wertungen}[$wertung - 1]{rang};
			    last if $fahrer_m->{wertungen}[$wertung - 1]{rang} !=
				    $fahrer_n->{wertungen}[$wertung - 1]{rang};
			    $fahrer_n->{wertungen}[$wertung - 1]{punkte} =
				($summe / $anzahl_fahrer) || undef;
			}
		    }
		} else {
		    foreach my $fahrer (@$fahrer_in_klasse) {
			my $wr = $fahrer->{wertungen}[$wertung - 1]{rang};
			next if $fahrer->{ausser_konkurrenz} ||
				$fahrer->{ausfall} ||
				$fahrer->{runden} < $runden ||
				!defined $wr;
			my $x = min($wr, scalar @$wertungspunkte);
			$fahrer->{wertungen}[$wertung - 1]{punkte} =
			    $wertungspunkte->[$x - 1] || undef;
		    }
		}
	    }
	}
    }
}

sub fahrer_nach_klassen($) {
    my ($fahrer_nach_startnummern) = @_;
    my $fahrer_nach_klassen;

    foreach my $fahrer (values %$fahrer_nach_startnummern) {
	my $klasse = $fahrer->{wertungsklasse};
	push @{$fahrer_nach_klassen->{$klasse}}, $fahrer
	    if defined $klasse;
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
	"geburtsdatum" => [ "Geb.datum", "l1", "title=\"Geburtsdatum\"" ],
	"lizenznummer" => [ "Lizenz", "l1", "title=\"Lizenznummer\"" ],
        "bundesland" =>  [ "Bl.", "l1", "title=\"Bundesland\"" ],
	"lbl" => [ "Land", "l1", "title=\"Land (Bundesland)\"" ],
    };
    if (exists $titel->{$feld}) {
	return $titel->{$feld};
    } else {
	return ucfirst $feld;
    }
}

sub spaltenwert($$) {
    my ($spalte, $fahrer) = @_;

    if ($spalte eq 'lbl') {
	my @text;

	$fahrer->{bundesland} =~ s/ *$//;
	if (($fahrer->{land} // '') ne '') {
	    push @text, $fahrer->{land};
	}
	if (($fahrer->{bundesland} // '') ne '') {
	    push @text, '(' . $fahrer->{bundesland} . ')';
	}
	return join(' ', @text);
    }

    return $fahrer->{$spalte} // "";
}

sub punkte_pro_sektion($$$) {
    my ($fahrer, $runde, $cfg) = @_;
    my $punkte_pro_sektion;

    my $klasse = $fahrer->{wertungsklasse};
    my $punkte_pro_runde = $fahrer->{punkte_pro_sektion}[$runde];
    my $auslassen = $cfg->{punkte_sektion_auslassen};
    foreach my $sektion (@{$cfg->{sektionen}[$klasse - 1]}) {
	my $p = $punkte_pro_runde->[$sektion - 1];
	push @$punkte_pro_sektion, defined $p ? ($p == -1 ? $auslassen : $p) : '-';
    }
    return join(" ", @$punkte_pro_sektion);
}

sub log10($) {
    my ($x) = @_;
    return log($x) / log(10)
}

sub wertungspunkte($$) {
    my ($wertungspunkte, $punkteteilung) = @_;
    return undef unless defined $wertungspunkte;
    my ($komma, $ganzzahl) = modf($wertungspunkte);
    if ($komma && $punkteteilung) {
	my $bruch_zeichen = {
	    # Unicode kennt folgende Zeichen für Brüche:
	    #   ⅛ ⅙ ⅕ ¼ ⅓ ⅜ ⅖ ½ ⅗ ⅝ ⅔ ¾ ⅘ ⅚ ⅞
	    #   ⁰¹²³⁴⁵⁶⁷⁸⁹ ⁄ ₀₁₂₃₄₅₆₇₈₉
	    # Z.B. Windows Vista unterstützt aber nur die Halben, Drittel, und
	    # Viertel, und auch die zusammengesetzten Brücke werden nicht
	    # sauber gerendert.
	    1/4 => '¼', 1/3 => '⅓', 1/2 => '½', 2/3 => '⅔', 3/4 => '¾',
	};
	my $eps = 1 / (1 << 13);

	foreach my $wert (keys %$bruch_zeichen) {
	    return "$ganzzahl$bruch_zeichen->{$wert}"
		if $komma >= $wert - $eps &&
		   $komma <= $wert + $eps;
	}
    }
    my $prec = 2; # Maximale Nachkommastellen
    return sprintf("%.*g", log10($wertungspunkte) + 1 + $prec, $wertungspunkte);
}

sub klassenstatistik($$$) {
    my ($fahrer_in_klasse, $fahrer_gesamt, $ausfall) = @_;

    foreach my $fahrer (@$fahrer_in_klasse) {
	if ($fahrer->{start}) {
	    $$fahrer_gesamt++;
	    $ausfall->{$fahrer->{ausfall}}++;
	    $ausfall->{ausser_konkurrenz}++
		if $fahrer->{ausser_konkurrenz};
	}
    }
}

sub fahrerstatistik($$) {
    my ($fahrer_nach_klassen, $klasse) = @_;

    my $fahrer_gesamt = 0;
    my $ausfall = {};

    if (defined $klasse) {
	my $fahrer_in_klasse = $fahrer_nach_klassen->{$klasse};
	klassenstatistik $fahrer_in_klasse, \$fahrer_gesamt, $ausfall;
   } else {
	foreach my $klasse (keys %$fahrer_nach_klassen) {
	    my $fahrer_in_klasse = $fahrer_nach_klassen->{$klasse};
	    klassenstatistik $fahrer_in_klasse, \$fahrer_gesamt, $ausfall;
	}
    }

    my @details;
    push @details, (($ausfall->{5} // 0) + ($ausfall->{6} // 0)) .
		   " nicht gestartet"
	if $ausfall->{5} || $ausfall->{6};
    push @details, "$ausfall->{3} ausgefallen"
	if $ausfall->{3};
    push @details, "$ausfall->{4} nicht gewertet"
	if $ausfall->{4};
    push @details, "$ausfall->{ausser_konkurrenz} außer Konkurrenz"
	if $ausfall->{ausser_konkurrenz};
    return "$fahrer_gesamt Fahrer" .
	(@details ? " (davon " . join(", ", @details) . ")" : "") . ".";
}

sub punkte_in_runde($) {
    my ($runde) = @_;

    if (defined $runde) {
	foreach my $punkte (@$runde) {
	    return 1 if defined $punkte;
	}
    }
    return "";
}

sub tageswertung(@) {
  # cfg fahrer_nach_startnummer wertung spalten klassenfarben alle_punkte
  # nach_relevanz klassen statistik_pro_klasse statistik_gesamt
    my %args = (
	klassenfarben => $Auswertung::klassenfarben,
	@_,
    );

    my $ausfall = {
	3 => "ausgefallen",
	4 => "nicht gewertet",
	5 => "nicht gestartet",
	6 => "nicht gestartet, entschuldigt"
    };

    wertungsklassen_setzen $args{fahrer_nach_startnummer}, $args{cfg};

    # Nur bestimmte Klassen anzeigen?
    if ($args{klassen}) {
	my $klassen = { map { $_ => 1 } @{$args{klassen}} };
	foreach my $startnummer (keys %{$args{fahrer_nach_startnummer}}) {
	    my $fahrer = $args{fahrer_nach_startnummer}{$startnummer};
	    delete $args{fahrer_nach_startnummer}{$startnummer}
		unless exists $klassen->{$fahrer->{wertungsklasse}};
	}
    }

    # Wir wollen, dass alle Tabellen gleich breit sind.
    my $namenlaenge = 0;
    foreach my $fahrer (values %{$args{fahrer_nach_startnummer}}) {
	next
	    unless $fahrer->{start};
	my $n = length "$fahrer->{nachname}, $fahrer->{vorname}";
	$namenlaenge = max($n, $namenlaenge);
    }

    my $zusatzpunkte;
    my $vierpunktewertung = $args{cfg}{vierpunktewertung} ? 1 : 0;
    foreach my $fahrer (values %{$args{fahrer_nach_startnummer}}) {
	$zusatzpunkte = 1
	    if $fahrer->{zusatzpunkte};
    }

    my $fahrer_nach_klassen = fahrer_nach_klassen($args{fahrer_nach_startnummer});
    doc_p fahrerstatistik($fahrer_nach_klassen, undef)
	if $args{statistik_gesamt};
    foreach my $klasse (sort {$a <=> $b} keys %$fahrer_nach_klassen) {
	my $fahrer_in_klasse = $fahrer_nach_klassen->{$klasse};
	my $runden = $args{cfg}{klassen}[$klasse - 1]{runden};
	my ($header, $body, $format);
	my $farbe = "";

	$fahrer_in_klasse = [
	    map { $_->{start} ? $_ : () } @$fahrer_in_klasse ];
	next unless @$fahrer_in_klasse > 0;

	my $stechen = 0;
	foreach my $fahrer (@$fahrer_in_klasse) {
	    $stechen = 1
	       if $fahrer->{stechen};
	}

	my $wertungspunkte;
	foreach my $fahrer (@$fahrer_in_klasse) {
	    $wertungspunkte = 1
		if defined $fahrer->{wertungen}[$args{wertung} - 1]{punkte};
	}

	my $ausfall_fmt = "c" . (5 + $vierpunktewertung + $stechen);

	if ($RenderOutput::html && exists $args{klassenfarben}{$klasse}) {
	    $farbe = "<span style=\"color:$args{klassenfarben}{$klasse}\">◼</span>";
	}

	print "\n<div class=\"klasse\" id=\"klasse$klasse\">\n"
	    if $RenderOutput::html;
	doc_h3 "$args{cfg}{klassen}[$klasse - 1]{bezeichnung}";
	push @$format, "r3", "r3", "l$namenlaenge";
	push @$header, [ "$farbe", "c" ], [ "Nr.", "r1", "title=\"Startnummer\"" ], "Name";
	foreach my $spalte (@{$args{spalten}}) {
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
	push @$format, "r3";
	push @$header, [ "Ges", "r1", "title=\"Gesamtpunkte\"" ];
	push @$format, "r2", "r2", "r2", "r2";
	push @$header, [ "0S", "r1", "title=\"Nuller\"" ];
	push @$header, [ "1S", "r1", "title=\"Einser\"" ];
	push @$header, [ "2S", "r1", "title=\"Zweier\"" ];
	push @$header, [ "3S", "r1", "title=\"Dreier\"" ];
	if ($vierpunktewertung) {
	    push @$format, "r2";
	    push @$header, [ "4S", "r1", "title=\"Vierer\"" ];
	}
	if ($stechen) {
	    push @$format, "r2";
	    push @$header, [ "ST", "r1", "title=\"Stechen\"" ];
	}
	push @$format, "r2";
	push @$header, [ "WP", "r1", "title=\"Wertungspunkte\"" ]
	    if $wertungspunkte;

	$fahrer_in_klasse = [ sort rang_wenn_definiert @$fahrer_in_klasse ];

	if ($args{nach_relevanz} && $RenderOutput::html) {
	    # Welche 0er, 1er, ... sind für den Rang relevant?
	    my $sn_alt = 0;
	    my $rn_alt = 0;
	    for (my $n = 0; $n < @$fahrer_in_klasse - 1; $n++) {
		my $a = $fahrer_in_klasse->[$n];
		my $b = $fahrer_in_klasse->[$n + 1];

		my $sn = 0;
		if ($a->{punkte} == $b->{punkte} &&
		    !$a->{stechen} && !$b->{stechen}) {
		    for (my $m = 0; $m < 5; $m++) {
			$sn++;
			last unless $a->{punkteverteilung}[$m] ==
				    $b->{punkteverteilung}[$m];
		    }
		}

		my $rn = 0;
		if ($sn == 5) {
		    my $ra = $a->{punkte_pro_runde};
		    my $rb = $b->{punkte_pro_runde};

		    if ($args{cfg}{wertungsmodus} == 1) {
			for (my $m = 0; $m < $runden; $m++) {
			    $rn++;
			    last unless $ra->[$m] == $rb->[$m];
			}
		    } elsif ($args{cfg}{wertungsmodus} == 2) {
			for (my $m = $runden - 1; $m >= 0; $m--) {
			    $rn++;
			    last unless $ra->[$m] == $rb->[$m];
			}
		    }
		}

		$a->{sn} = max($sn_alt, $sn);
		$a->{rn} = max($rn_alt, $rn);
		$sn_alt = $sn;
		$rn_alt = $rn;
	    }
	    $fahrer_in_klasse->[@$fahrer_in_klasse - 1]{sn} = $sn_alt;
	    $fahrer_in_klasse->[@$fahrer_in_klasse - 1]{rn} = $rn_alt;
	}

	foreach my $fahrer (@$fahrer_in_klasse) {
	    my $row;
	    if (!($fahrer->{ausser_konkurrenz} || $fahrer->{ausfall})) {
		push @$row, "$fahrer->{rang}.";
	    } else {
		push @$row, "";
	    }
	    push @$row, $fahrer->{startnummer};
	    push @$row, $fahrer->{nachname} . " " . $fahrer->{vorname};
	    foreach my $spalte (@{$args{spalten}}) {
		push @$row, spaltenwert($spalte, $fahrer);
	    }
	    for (my $n = 0; $n < $runden; $n++) {
		my $punkte;
		my $fmt;
		my $class;

		if (punkte_in_runde($fahrer->{punkte_pro_sektion}[$n])) {
		    $punkte = $fahrer->{punkte_pro_runde}[$n] // "-";
		    if ($n >= $fahrer->{runden} && $RenderOutput::html) {
			push @$class, "incomplete";
		    }
		    if ($args{alle_punkte}) {
			my $punkte_pro_sektion = punkte_pro_sektion($fahrer, $n, $args{cfg});
			push @$fmt, "title=\"$punkte_pro_sektion\"";
		    }
		} elsif ($fahrer->{ausfall} != 0 && $fahrer->{ausfall} != 4) {
		    $punkte = "-";
		}

		if (!defined $fahrer->{rn} ||
		    ($args{cfg}{wertungsmodus} == 0 ||
		     ($args{cfg}{wertungsmodus} == 1 && $n >= $fahrer->{rn}) ||
		     ($args{cfg}{wertungsmodus} == 2 && $n < $runden - $fahrer->{rn}) ||
		     $fahrer->{ausfall} != 0)) {
		    push @$class, "info";
		} else {
		    push @$class, "info2";
		}

		push @$fmt, "class=\"" . join(" ", @$class) . "\""
		    if $class;
		if ($fmt) {
		    push @$row, [ $punkte, "r1", join(" ", @$fmt) ];
		} else {
		    push @$row, $punkte;
		}
	    }
	    push @$row, $fahrer->{zusatzpunkte} || ""
		if $zusatzpunkte;

	    if ($fahrer->{ausser_konkurrenz} || $fahrer->{ausfall} || $fahrer->{runden} == 0) {
		my @details = ();
		push @details, "außer konkurrenz"
		    if $fahrer->{ausser_konkurrenz};
		push @details, $ausfall->{$fahrer->{ausfall}}
		    if $fahrer->{ausfall};
		push @$row, [ join(", ", @details), $ausfall_fmt ];
	    } else {
		push @$row, $fahrer->{punkte} // "";
		for (my $n = 0; $n < 4 + $vierpunktewertung; $n++) {
		    if ($n < ($fahrer->{sn} // -1)) {
			push @$row, [ $fahrer->{punkteverteilung}[$n], "r", "class=\"info2\"" ];
		    } else {
			push @$row, [ $fahrer->{punkteverteilung}[$n], "r", "class=\"info\"" ];
		    }
		}
		if ($stechen) {
		    my $x = $fahrer->{stechen} ? "$fahrer->{stechen}." : undef;
		    $x = [ $x, "r1", "class=\"info2\"" ]
			if $x && $args{nach_relevanz};
		    push @$row, $x;
		}
	    }

	    push @$row, wertungspunkte($fahrer->{wertungen}[$args{wertung} - 1]{punkte},
				       $args{cfg}{punkteteilung})
		if $wertungspunkte;
	    push @$body, $row;
	}
	doc_table header => $header, body => $body, format => $format;
	doc_p fahrerstatistik($fahrer_nach_klassen, $klasse)
	    if $args{statistik_pro_klasse};
	print "</div>\n"
	    if $RenderOutput::html;
    }
}

sub streichen($$$$) {
    my ($klasse, $laeufe_bisher, $laeufe_gesamt, $streichresultate) = @_;

    $laeufe_gesamt = $laeufe_gesamt->{$klasse}
	if ref($laeufe_gesamt) eq 'HASH';
    $streichresultate = $streichresultate->{$klasse}
	if ref($streichresultate) eq 'HASH';

    $laeufe_gesamt = max($laeufe_bisher, $laeufe_gesamt);
    return $laeufe_bisher - max(0, $laeufe_gesamt - $streichresultate);
}

sub wertungsrang_cmp($$) {
    my ($a, $b) = @_;

    return defined $b <=> defined $a
	unless defined $a && defined $b;
    return $a <=> $b;
}

sub jahreswertung_cmp($$) {
    my ($aa, $bb) = @_;

    # Höhere Gesamtpunkte (nach Abzug der Streichpunkte) gewinnen
    return $bb->{gesamtpunkte} <=> $aa->{gesamtpunkte}
	if $aa->{gesamtpunkte} != $bb->{gesamtpunkte};

    # Fahrer mit mehr guten Platzierungen (ohne Beachtung von Streichresultaten) gewinnt
    my $ra = [ sort wertungsrang_cmp @{$aa->{wertungsrang}} ];
    my $rb = [ sort wertungsrang_cmp @{$bb->{wertungsrang}} ];

    for (my $n = 0; $n < @$ra && $n < @$rb; $n++) {
	my $cmp = wertungsrang_cmp($ra->[$n], $rb->[$n]);
	if ($cmp) {
	    my $rang = ($cmp < 0) ? $ra->[$n] : $rb->[$n];
	    $aa->{rang_wichtig}{$rang}++;
	    $bb->{rang_wichtig}{$rang}++;
	    return $cmp;
	}
    }

    foreach my $rang (keys %{$aa->{rang_wichtig}}) {
	$bb->{rang_wichtig}{$rang}++
	   unless $bb->{rang_wichtig}{$rang};
    }
    foreach my $rang (keys %{$bb->{rang_wichtig}}) {
	$aa->{rang_wichtig}{$rang}++
	   unless $aa->{rang_wichtig}{$rang};
    }

    # Fahrer mit höheren Streichpunkten gewinnt
    my $cmp = ($bb->{streichpunkte} // 0) <=> ($aa->{streichpunkte} // 0);
    if ($cmp) {
	$aa->{streichpunkte_wichtig}++;
	$bb->{streichpunkte_wichtig}++;
	return $cmp;
    }

    $bb->{streichpunkte_wichtig}++
	if $aa->{streichpunkte_wichtig};
    $aa->{streichpunkte_wichtig}++
	if $bb->{streichpunkte_wichtig};

    # TODO: Ist auch dann noch keine Differenzierung möglich, wird der
    # OSK-Prädikatstitel dem Fahrer zuerkannt, der den letzten wertbaren Lauf
    # zu dem entsprechenden Bewerb gewonnen hat.

    return $cmp;
}

sub jahreswertung_berechnen($$$) {
    my ($jahreswertung, $laeufe_gesamt, $streichresultate) = @_;

    foreach my $klasse (keys %$jahreswertung) {
	foreach my $startnummer (keys %{$jahreswertung->{$klasse}}) {
	    my $fahrer = $jahreswertung->{$klasse}{$startnummer};
	    $jahreswertung->{$klasse}{$startnummer}{startnummer} = $startnummer;
	}

	my $fahrer_in_klasse = [ map { $jahreswertung->{$klasse}{$_} }
				     keys %{$jahreswertung->{$klasse}} ];

	# Gesamtpunkte und Streichpunkte berechnen
	foreach my $fahrer (@$fahrer_in_klasse) {
	    my $wertungspunkte = $fahrer->{wertungspunkte};
	    my $n = 0;
	    if (defined $streichresultate) {
		my $laeufe_bisher = @$wertungspunkte;
		my $streichen = streichen($klasse, $laeufe_bisher, $laeufe_gesamt,
					  $streichresultate);
		if ($streichen > 0) {
		    $fahrer->{streichpunkte} = 0;
		    $wertungspunkte = [ sort { $a <=> $b }
					     @$wertungspunkte ];
		    for (; $n < $streichen; $n++) {
			$fahrer->{streichpunkte} += $wertungspunkte->[$n];
		    }
		}
	    }
	    $fahrer->{gesamtpunkte} = 0;
	    for (; $n < @$wertungspunkte; $n++) {
		$fahrer->{gesamtpunkte} += $wertungspunkte->[$n];
	    }
	}

	# Gesamtrang berechnen
	my $gesamtrang = 1;
	my $vorheriger_fahrer;
	foreach my $fahrer (sort jahreswertung_cmp @$fahrer_in_klasse) {
	    $fahrer->{gesamtrang} =
		$vorheriger_fahrer &&
		jahreswertung_cmp($vorheriger_fahrer, $fahrer) == 0 ?
		    $vorheriger_fahrer->{gesamtrang} : $gesamtrang;
	    $gesamtrang++;
	    $vorheriger_fahrer = $fahrer;
	}
    }
}

sub jahreswertung_anzeige_cmp($$) {
    my ($aa, $bb) = @_;

    return $aa->{gesamtrang} <=> $bb->{gesamtrang}
	if $aa->{gesamtrang} != $bb->{gesamtrang};
    return $aa->{startnummer} <=> $bb->{startnummer};
}

sub jahreswertung_zusammenfassung($$$$) {
    my ($klasse, $laeufe_bisher, $laeufe_gesamt, $streichresultate) = @_;

    my $klasse_laeufe_gesamt = ref($laeufe_gesamt) eq 'HASH' ?
	$laeufe_gesamt->{$klasse} : $laeufe_gesamt;
    my $klasse_streichresultate = ref($streichresultate) eq 'HASH' ?
	$streichresultate->{$klasse} : $streichresultate;

    my @l;
    if (defined $laeufe_bisher && defined $klasse_laeufe_gesamt) {
	push @l, "Stand nach $laeufe_bisher von $klasse_laeufe_gesamt " .
		 ($klasse_laeufe_gesamt == 1 ? "Lauf" : "Läufen");
    }
    if (defined $klasse_streichresultate) {
	my $streichen = streichen($klasse, $laeufe_bisher, $laeufe_gesamt,
				  $streichresultate);
	if ($streichen > 0) {
	    push @l, "$streichen von $klasse_streichresultate " .
		     ($klasse_streichresultate == 1 ?
		      "Streichresultat" : "Streichresultaten") .
		     " berücksichtigt";
	}
    }
    return @l ? (join(", ", @l) . ".") : "";
}

sub jahreswertung(@) {
    # veranstaltungen wertung laeufe_gesamt streichresultate klassenfarben
    # spalten klassen nach_relevanz
    my %args = (
	klassenfarben => $Auswertung::klassenfarben,
	@_,
    );

    my $wertung = $args{wertung};
    undef $args{streichresultate}
	unless defined $args{laeufe_gesamt};

    foreach my $veranstaltung (@{$args{veranstaltungen}}) {
	my $cfg = $veranstaltung->[0];
	my $fahrer_nach_startnummer = $veranstaltung->[1];
	wertungsklassen_setzen $fahrer_nach_startnummer, $cfg;
    }

    if ($args{klassen}) {
	my $klassen = { map { $_ => 1 } @{$args{klassen}} };
	foreach my $veranstaltung (@{$args{veranstaltungen}}) {
	    my $fahrer_nach_startnummer = $veranstaltung->[1];
	    foreach my $startnummer (keys %$fahrer_nach_startnummer) {
		my $fahrer = $fahrer_nach_startnummer->{$startnummer};
		delete $fahrer_nach_startnummer->{$startnummer}
		    unless exists $klassen->{$fahrer->{wertungsklasse}};
	    }
	}
    }

    for (my $n = 0; $n < @{$args{veranstaltungen}}; $n++) {
	my $veranstaltung = $args{veranstaltungen}[$n];
	my $cfg = $veranstaltung->[0];
	my $neue_startnummern = $cfg->{neue_startnummern};
	if ($neue_startnummern && %$neue_startnummern) {
	    # Startnummern umschreiben und kontrollieren, ob Startnummern
	    # doppelt verwendet wurden

	    my $fahrer_nach_startnummer;
	    foreach my $fahrer (values %{$veranstaltung->[1]}) {
		my $startnummer = $fahrer->{startnummer};
		if (exists $neue_startnummern->{$startnummer}) {
		    my $neue_startnummer = $neue_startnummern->{$startnummer};
		    next unless defined $neue_startnummer;

		    $fahrer->{alte_startnummer} = $fahrer->{startnummer};
		    $fahrer->{startnummer} = $neue_startnummer;
		    $startnummer = $neue_startnummer;
		}
		if (exists $fahrer_nach_startnummer->{$startnummer}) {
		    my $fahrer2 = $fahrer_nach_startnummer->{$startnummer};

		    if (defined $fahrer2->{wertungen}[$wertung - 1]{punkte}) {
			next unless defined $fahrer->{wertungen}[$wertung - 1]{punkte};
			doc_p "Veranstaltung " . ($n + 1) . ": Fahrer " .
			      ($fahrer->{alte_startnummer} // $fahrer->{startnummer}) .
			      " und " .
			      ($fahrer2->{alte_startnummer} // $fahrer2->{startnummer}) .
			      " verwenden beide die Startnummer $startnummer in der " .
			      "Jahreswertung!";
			return;
		    }
		}
		$fahrer_nach_startnummer->{$startnummer} = $fahrer;
	    }
	    $veranstaltung->[1] = $fahrer_nach_startnummer;
	}
    }

    my $laeufe_pro_klasse;
    foreach my $veranstaltung (@{$args{veranstaltungen}}) {
	my $cfg = $veranstaltung->[0];
	foreach my $fahrer (values %{$veranstaltung->[1]}) {
	    $cfg->{gewertet}[$fahrer->{wertungsklasse} - 1] = 1
		if defined $fahrer->{wertungen}[$wertung - 1]{punkte};
	}
	if (exists $cfg->{gewertet}) {
	    for (my $n = 0; $n < @{$cfg->{gewertet}}; $n++) {
		$laeufe_pro_klasse->{$n + 1}++
		    if defined $cfg->{gewertet}[$n];
	    }
	}
    }

    my $punkteteilung;
    foreach my $veranstaltung (@{$args{veranstaltungen}}) {
	my $cfg = $veranstaltung->[0];
	$punkteteilung++
	    if $cfg->{punkteteilung};
    }

    my $zusammenfassung;
    foreach my $klasse (keys %$laeufe_pro_klasse) {
	$zusammenfassung->{$klasse} = jahreswertung_zusammenfassung(
		$klasse, $laeufe_pro_klasse->{$klasse},
		$args{laeufe_gesamt}, $args{streichresultate});
    }

    my $gemeinsame_zusammenfassung;
    foreach my $klasse (keys %$zusammenfassung) {
	if (defined $gemeinsame_zusammenfassung) {
	    if ($gemeinsame_zusammenfassung ne $zusammenfassung->{$klasse}) {
		$gemeinsame_zusammenfassung = undef;
		last;
	    }
	} else {
	    $gemeinsame_zusammenfassung = $zusammenfassung->{$klasse};
	}
    }

    my $spaltenbreite = 2;
    #foreach my $veranstaltung (@{$args{veranstaltungen}}) {
    #	my $cfg = $veranstaltung->[0];
    #	my $l = length $cfg->{label};
    #	$spaltenbreite = $l
    #	    if $l > $spaltenbreite;
    #}

    my $alle_fahrer;

    my $jahreswertung;
    foreach my $veranstaltung (@{$args{veranstaltungen}}) {
	my $fahrer_nach_startnummer = $veranstaltung->[1];

	foreach my $fahrer (values %$fahrer_nach_startnummer) {
	    my $startnummer = $fahrer->{startnummer};
	    if (defined $fahrer->{wertungen}[$wertung - 1]{punkte}) {
		my $klasse = $fahrer->{wertungsklasse};
		push @{$jahreswertung->{$klasse}{$startnummer}{wertungspunkte}},
		    $fahrer->{wertungen}[$wertung - 1]{punkte};
		push @{$jahreswertung->{$klasse}{$startnummer}{wertungsrang}},
		    $fahrer->{wertungen}[$wertung - 1]{rang};
	    }
	    $alle_fahrer->{$startnummer} = $fahrer;
	}
    }

    my $letzte_cfg = $args{veranstaltungen}[@{$args{veranstaltungen}} - 1][0];

    jahreswertung_berechnen $jahreswertung, $args{laeufe_gesamt}, $args{streichresultate};

    # Wir wollen, dass alle Tabellen gleich breit sind.
    my $namenlaenge = 0;
    foreach my $fahrer (map { $alle_fahrer->{$_} }
			    map { keys %$_ } values %$jahreswertung) {
	my $n = length "$fahrer->{nachname}, $fahrer->{vorname}";
	$namenlaenge = max($n, $namenlaenge);
    }

    doc_p $gemeinsame_zusammenfassung
	if defined $gemeinsame_zusammenfassung;

    foreach my $klasse (sort {$a <=> $b} keys %$jahreswertung) {
	my $klassenwertung = $jahreswertung->{$klasse};
	my $fahrer_in_klasse = [
	    map { $alle_fahrer->{$_->{startnummer}} }
		(sort jahreswertung_anzeige_cmp values %$klassenwertung) ];

	my $hat_streichpunkte;
	if (defined $args{streichresultate}) {
	    my $laeufe_bisher = $laeufe_pro_klasse->{$klasse};
	    my $streichen = streichen($klasse, $laeufe_bisher, $args{laeufe_gesamt},
				      $args{streichresultate});
	    $hat_streichpunkte = $streichen > 0;
	    #foreach my $fahrer (@$fahrer_in_klasse) {
	    #	my $startnummer = $fahrer->{startnummer};
	    #	my $fahrerwertung = $klassenwertung->{$startnummer};
	    #	if (defined $fahrerwertung->{streichpunkte}) {
	    #	    $hat_streichpunkte = 1;
	    #	    last;
	    #	}
	    #}
	}

	doc_h3 "$letzte_cfg->{klassen}[$klasse - 1]{bezeichnung}";

	doc_p $zusammenfassung->{$klasse}
	    unless defined $gemeinsame_zusammenfassung;

	my ($header, $body, $format);
	my $farbe = "";
	if ($RenderOutput::html && exists $args{klassenfarben}{$klasse}) {
	    $farbe = "<span style=\"color:$args{klassenfarben}{$klasse}\">◼</span>";
	}
	push @$format, "r3", "r3", "l$namenlaenge";
	push @$header, [ $farbe, "c" ], [ "Nr.", "r1", "title=\"Startnummer\"" ], "Name";
	foreach my $spalte (@{$args{spalten}}) {
	    push @$format, "l";
	    push @$header, spaltentitel($spalte);
	}
	for (my $n = 0; $n < @{$args{veranstaltungen}}; $n++) {
	    my $cfg = $args{veranstaltungen}[$n][0];
	    my $gewertet = $cfg->{gewertet}[$klasse - 1];
	    if ($gewertet) {
		push @$format, "r$spaltenbreite";
		push @$header,  $gewertet ? [ $cfg->{label}, "r1", "title=\"$cfg->{wertungen}[$wertung - 1]{titel}\"" ] : "";
	    }
	}
	if ($hat_streichpunkte) {
	    push @$format, "r3";
	    push @$header, [ "Str", "r1", "title=\"Streichpunkte\"" ];
	}
	push @$format, "r3";
	push @$header, [ "Ges", "r1", "title=\"Gesamtpunkte\"" ];

	foreach my $fahrer (@$fahrer_in_klasse) {
	    my $startnummer = $fahrer->{startnummer};
	    my $fahrerwertung = $klassenwertung->{$startnummer};
	    my $row;
	    push @$row, $fahrerwertung->{gesamtpunkte} ? "$fahrerwertung->{gesamtrang}." : "";
	    push @$row, $startnummer,
			$alle_fahrer->{$startnummer}{nachname} . " " .
			$alle_fahrer->{$startnummer}{vorname};
	    foreach my $spalte (@{$args{spalten}}) {
		push @$row, spaltenwert($spalte, $fahrer);
	    }
	    for (my $n = 0; $n < @{$args{veranstaltungen}}; $n++) {
		my $veranstaltung = $args{veranstaltungen}[$n];
		my $gewertet = $veranstaltung->[0]{gewertet}[$klasse - 1];
		my $fahrer = $veranstaltung->[1]{$startnummer};
		if ($gewertet) {
		    my $wertungspunkte = $fahrer->{wertungen}[$wertung - 1]{punkte};
		    my $feld = (defined $wertungspunkte &&
				$fahrer->{wertungsklasse} == $klasse) ?
				wertungspunkte($wertungspunkte, $punkteteilung) :
				$RenderOutput::html ? "" : "-";
		    my $wertungsrang = $fahrer->{wertungen}[$wertung - 1]{rang};
		    $feld = [ $feld, "r", "class=\"text2\"" ]
			if defined $wertungsrang &&
			   $fahrerwertung->{rang_wichtig}{$wertungsrang} &&
			   $args{nach_relevanz};
		    push @$row, $feld;
		}
	    }
	    if ($hat_streichpunkte) {
		my $feld = wertungspunkte($fahrerwertung->{streichpunkte}, $punkteteilung);
		$feld = [ $feld, "r", "class=\"text2\"" ]
		    if $fahrerwertung->{streichpunkte_wichtig} &&
		       $args{nach_relevanz};
		push @$row, $feld;
	    }
	    push @$row, wertungspunkte($fahrerwertung->{gesamtpunkte}, $punkteteilung);
	    push @$body, $row;
	}
	doc_table header => $header, body => $body, format => $format;
    }

    doc_h3 "Veranstaltungen:";
    my $body;
    for (my $n = 0; $n < @{$args{veranstaltungen}}; $n++) {
	my $cfg = $args{veranstaltungen}[$n][0];
	next unless exists $cfg->{gewertet} && @{$cfg->{gewertet}};

	my $label = defined $cfg->{label2} ? $cfg->{label2} : $cfg->{label};

	#push @$body, [ $label, "$cfg->{wertungen}[$wertung - 1]{titel}: $cfg->{wertungen}[$wertung - 1]{subtitel}" ];
	push @$body, [ $label, $cfg->{wertungen}[$wertung - 1]{titel} ];
    }
    doc_table header => ["", "Name"], body => $body, format => ["r", "l"];
}

1;