'use strict;'

function listeController($scope, $route, $location, veranstaltung, fahrerliste) {
  $scope.veranstaltung = veranstaltung;
  $scope.features = features_aus_liste(veranstaltung);
  $scope.fold = {};
  $scope.anzeige = { felder: [] };

  var versicherungen = {
    1: 'ADAC-Versicherung',
    2: 'DMV-Versicherung',
    3: 'KFZ-Versicherung',
    4: 'Tagesversicherung'
  };

  angular.forEach(fahrerliste, function(fahrer) {
    var match;
    if (fahrer.geburtsdatum !== null &&
	(match = fahrer.geburtsdatum.match(/^(\d{4})-(\d{2})-(\d{2})$/)))
      fahrer.geburtsdatum = new Date(match[1], match[2], match[3]);
    if (fahrer.startzeit !== null &&
	(match = fahrer.startzeit.match(/^(\d{2}):(\d{2}):(\d{2})$/)))
      fahrer.startzeit = new Date(0, 0, 0, match[1], match[2], match[3]);
    if (fahrer.zielzeit !== null &&
	(match = fahrer.zielzeit.match(/^(\d{2}):(\d{2}):(\d{2})$/)))
      fahrer.zielzeit = new Date(0, 0, 0, match[1], match[2], match[3]);

    if (fahrer.versicherung !== null && versicherungen[fahrer.versicherung])
      fahrer.versicherung = versicherungen[fahrer.versicherung];

    var wertungen = [];
    angular.forEach(fahrer.wertungen, function(wertung) {
      wertungen[wertung - 1] = true;
    });
    fahrer.wertungen = wertungen;
  });

  $scope.land_bundesland = function(fahrer) {
    var land_bundesland = [];
    if (fahrer.land)
      land_bundesland.push(fahrer.land);
    if (fahrer.bundesland)
      land_bundesland.push('(' + fahrer.bundesland + ')');
    return land_bundesland.join(' ');
  }

  var definierte_felder = {
    startnummer: 
      { bezeichnung: 'Nr.',
	ausdruck: "startnummer < 0 ? null : startnummer",
	style: { 'text-align': 'center' } },
    klasse:
      { bezeichnung: 'Kl.',
	ausdruck: "klasse",
	style: { 'text-align': 'center' } },
    name:
      { bezeichnung: 'Name',
	ausdruck: "nachname + ' ' + vorname",
	style: { 'text-align': 'left' } },
    geburtsdatum:
      { bezeichnung: 'Geburtsdatum',
	ausdruck: "geburtsdatum | date:'d.M.yyyy'",
	style: { 'text-align': 'center' } },
    wohnort:
      { bezeichnung: 'Wohnort',
	ausdruck: "wohnort",
	style: { 'text-align': 'left' } },
    club:
      { bezeichnung: 'Club',
	ausdruck: "club",
	style: { 'text-align': 'left' } },
    fahrzeug:
      { bezeichnung: 'Fahrzeug',
	ausdruck: "fahrzeug",
	style: { 'text-align': 'left' } },
    lbl:
      { bezeichnung: 'Land',
	ausdruck: "land_bundesland(fahrer)",
	style: { 'text-align': 'left' } },
    startzeit:
      { bezeichnung: 'Startzeit',
	ausdruck: "startzeit | date:'H:mm'",
	style: { 'text-align': 'center' } },
    zielzeit:
      { bezeichnung: 'Zielzeit',
	ausdruck: "zielzeit | date:'H:mm'",
	style: { 'text-align': 'center' } },
    nennungseingang:
      { bezeichnung: 'Nennungseingang',
	ausdruck: "nennungseingang ? 'Ja' : ''",
	style: { 'text-align': 'center' } },
    papierabnahme:
      { bezeichnung: 'Papierabnahme',
	ausdruck: "papierabnahme ? 'Ja' : ''",
	style: { 'text-align': 'center' } },
    papierabnahme_morgen:
      { bezeichnung: 'Papierabnahme morgen',
	ausdruck: "papierabnahme_morgen ? 'Ja' : ''",
	style: { 'text-align': 'center' } },
    versicherung:
      { bezeichnung: 'Versicherung',
	ausdruck: "versicherung",
	style: { 'text-align': 'left' } },
    lizenznummer:
      { bezeichnung: 'Lizenznr.',
	ausdruck: "lizenznummer",
	style: { 'text-align': 'left' } },
  };

  $scope.feldliste = (function() {
    var feldliste = [
      { value: 'name', name: 'Name' }
    ];
    angular.forEach([
      { value: 'club', name: 'Club' },
      { value: 'fahrzeug', name: 'Fahrzeug' },
      { value: 'geburtsdatum', name: 'Geburtsdatum' },
      { value: 'klasse', name: 'Klasse' },
      { value: 'lizenznummer', name: 'Lizenznummer' },
      { value: 'papierabnahme', name: 'Papierabnahme' },
      { value: 'papierabnahme_morgen', name: 'Papierabnahme morgen' },
      { value: 'startnummer', name: 'Startnummer' },
      { value: 'versicherung', name: 'Versicherung' },
      { value: 'wohnort', name: 'Wohnort' },
      { value: 'startzeit', name: 'Startzeit' },
      { value: 'zielzeit', name: 'Zielzeit' },
      { value: 'nennungseingang', name: 'Nennungseingang' }
    ], function(feld) {
      if ($scope.features[feld.value])
	feldliste.push(feld);
    });
    if ($scope.features.land || $scope.features.bundesland)
      feldliste.push({ value: 'lbl', name: 'Land (Bundesland)' });
    angular.forEach([1, 2, 3, 4], function(wertung) {
      if ($scope.features['wertung' + wertung]) {
	var bezeichnung = veranstaltung.wertungen[wertung - 1].bezeichnung;
	feldliste.push({ value: 'wertung' + wertung, name: bezeichnung });
	definierte_felder['wertung' + wertung] = {
	  bezeichnung: bezeichnung,
	  ausdruck: "wertungen[" + (wertung - 1) + "] ? 'Ja' : ''",
	  style: { 'text-align': 'center' }
	};
      }
    });
    return feldliste.sort(function(a, b) { return a.name.localeCompare(b.name); });
  })();

  function generic_compare(v1, v2) {
    var t1 = typeof v1;
    var t2 = typeof v2;
    if (t1 == t2) {
      if (v1 === v2)
	return 0;
      if (t1 == 'string')
	return v1.localeCompare(v2);
      else
        return v1 < v2 ? -1 : 1;
    } else
      return t1 < t2 ? -1 : 1;
  };

  function filter(fahrer) {
    var anzeige = $scope.anzeige;
    if (anzeige.startnummer !== null &&
	(fahrer.startnummer >= 0) !== anzeige.startnummer)
      return false;
    if (anzeige.nennungseingang !== null &&
	fahrer.nennungseingang !== anzeige.nennungseingang)
      return false;
    if (anzeige.papierabnahme !== null &&
	fahrer.papierabnahme !== anzeige.papierabnahme)
      return false;
    for (var wertung = 1; wertung <= 4; wertung++) {
      if (anzeige['wertung' + wertung] !== null &&
	  (fahrer.wertungen[wertung - 1] === true) !==
	  anzeige['wertung' + wertung])
	return false;
    }
    if (anzeige.min !== null &&
	fahrer.startnummer < anzeige.min)
      return false;
    if (anzeige.max !== null &&
	fahrer.startnummer > anzeige.max)
      return false;
    return anzeige.klassen[fahrer.klasse === null ? '-' : fahrer.klasse];
  }

  function klasse_compare(f1, f2) {
    return generic_compare(f1.klasse, f2.klasse);
  }

  function make_compare(comparators) {
    return function(f1, f2) {
      for (var n = 0; n < comparators.length; n++) {
	var cmp = comparators[n](f1, f2);
	if (cmp)
	  return cmp;
      }
      return 0;
    }
  }

  function group_by(array, comparator) {
    var result = [];
    if (!array.length)
      return [];
    var group = [array[0]];
    for (var n = 1; n != array.length; n++) {
      if (comparator(group[0], array[n])) {
	result.push(group);
	group = [];
      }
	group.push(array[n]);
    }
    result.push(group);
    return result;
  }

  var gruppieren_funktionen = {
    klasse: {
      heading: function(f) {
	return f.klasse > 0 ?
	       veranstaltung.klassen[f.klasse - 1].bezeichnung :
	       'Keiner Klasse zugeordnet'
      },
      compare: function(f1, f2) {
	return generic_compare(f1.klasse, f2.klasse);
      }
    },
    wohnort: {
      heading: function(f) {
	return f.wohnort || 'Wohnort nicht bekannt';
      },
      compare: function(f1, f2) {
	return generic_compare(f1.wohnort, f2.wohnort);
      }
    },
    fahrzeug: {
      heading: function(f) {
	return f.fahrzeug || 'Fahrzeug nicht bekannt';
      },
      compare: function(f1, f2) {
	return generic_compare(f1.fahrzeug, f2.fahrzeug);
      }
    },
    club: {
      heading: function(f) {
	return f.club || 'Kein Club oder Club nicht bekannt';
      },
      compare: function(f1, f2) {
	return generic_compare(f1.club, f2.club);
      }
    },
    versicherung: {
      heading: function(f) {
	return f.versicherung || 'Versicherung nicht bekannt';
      },
      compare: function(f1, f2) {
	return generic_compare(f1.versicherung, f2.versicherung);
      }
    },
    lbl: {
      heading: function(f) {
	var lbl = $scope.land_bundesland(f);
	return lbl === '' ? 'Land / Bundesland nicht bekannt' : lbl;
      },
      compare: function(f1, f2) {
	return generic_compare(f1.land, f2.land) ||
	       generic_compare(f1.bundesland, f2.bundesland);
      }
    }
  };

  var sortieren_funktionen = {
    startnummer: function(f1, f2) {
      return generic_compare(f1.startnummer, f2.startnummer);
    },
    name: function(f1, f2) {
      return generic_compare(f1.nachname, f2.nachname) ||
	     generic_compare(f1.vorname, f2.vorname);
    },
    geburtsdatum: function(f1, f2) {
      return generic_compare(f2.geburtsdatum, f1.geburtsdatum);
    },
    startzeit: function(f1, f2) {
      return generic_compare(f1.startzeit, f2.startzeit);
    },
    zielzeit: function(f1, f2) {
      return generic_compare(f1.zielzeit, f2.zielzeit);
    },
  };

  $scope.gruppe_ueberschrift = function(gruppe) {
    var gruppieren = gruppieren_funktionen[$scope.anzeige.gruppierung];
    if (gruppieren)
      return gruppieren.heading(gruppe[0]);
  };

  var tristate_optionen = (function() {
    var felder = ['startnummer', 'nennungseingang', 'papierabnahme'];
    for (var n = 1; n <= 4; n++)
      felder.push('wertung' + n);
    return felder;
  })();

  function startende_klassen() {
    var klassen = {};
    angular.forEach(veranstaltung.sektionen, function(sektionen, index) {
      if (sektionen && sektionen.length)
	klassen[index + 1] = true;
    });
    return klassen;
  }

  function von_url(anzeige) {
    angular.forEach(tristate_optionen, function(option) {
      if (anzeige[option] === 'yes')
	anzeige[option] = true;
      else if (anzeige[option] === 'no')
	anzeige[option] = false;
      else
	anzeige[option] = null;
    });
    angular.forEach(['min', 'max'], function(option) {
      if (anzeige[option] === undefined)
	anzeige[option] = null;
      else
        anzeige[option] = +anzeige[option];
    });

    var klassen = startende_klassen();
    klassen['-'] = true;
    angular.forEach(anzeige.klasse, function(klasse) {
      klassen[klasse] = false;
    });
    anzeige.klassen = klassen;
    delete anzeige.klasse;

    var felder = anzeige.feld || [];
    if (typeof felder === 'string')
      felder = [felder];
    if (felder.length == 0 || felder[felder.length - 1] !== '')
      felder.push('');
    anzeige.felder = felder;
    delete anzeige.feld;

    return anzeige;
  }

  function nach_url() {
    var anzeige = angular.copy($scope.anzeige);

    angular.forEach(tristate_optionen, function(option) {
      if (anzeige[option] !== null)
	anzeige[option] = anzeige[option] ? 'yes' : 'no';
    });

    var versteckte_klassen = [];
    angular.forEach(anzeige.klassen, function(value, key) {
      if (value === false)
	versteckte_klassen.push(key);
    });
    if (versteckte_klassen.length)
      anzeige.klasse = versteckte_klassen;
    delete anzeige.klassen;

    var felder = anzeige.felder;
    if (felder[felder.length - 1] === '')
      felder.pop();
    anzeige.feld = felder;
    delete anzeige.felder;

    angular.forEach(anzeige, function(value, key) {
      if (value === null || value === '')
	delete anzeige[key];
    });
    return anzeige;
  }

  function url_aktualisieren() {
    var url_alt = $location.search();
    var url_neu = nach_url();
    if (!angular.equals(url_alt, url_neu))
      $location.search(url_neu).replace();
  }

  function aktualisieren() {
    var ergebnisliste = [];
    angular.forEach(fahrerliste, function(fahrer) {
      if (filter(fahrer))
	ergebnisliste.push(fahrer);
    });
    var gruppieren = gruppieren_funktionen[$scope.anzeige.gruppierung];
    var sortieren = sortieren_funktionen[$scope.anzeige.reihenfolge];
    comparators = [];
    if (gruppieren)
      comparators.push(gruppieren.compare);
    if (sortieren)
      comparators.push(sortieren);
    ergebnisliste = ergebnisliste.sort(make_compare(comparators));
    $scope.ergebnisliste = gruppieren ?
      group_by(ergebnisliste, gruppieren.compare) :
      [ergebnisliste];
    url_aktualisieren();
  };

  $scope.nur_wenn_positiv = function(x) {
    if (x > 0)
      return x;
  };

  $scope.$watch('anzeige.startnummer', function() {
    if ($scope.anzeige.startnummer !== true) {
      $scope.anzeige.nennungseingang = null;
      $scope.anzeige.papierabnahme = null;
    }
  });
  $scope.$watch('anzeige', aktualisieren, true);
  $scope.$watch('anzeige.felder', function() {
    var felder = $scope.anzeige.felder;
    for (var n = 0; n < felder.length - 1; n++)
      if (felder[n] === '')
	felder.splice(n, 1);
    if (felder[felder.length - 1] !== '')
      felder.push('');

    $scope.felder = [];
    for (var n = 0; n < felder.length - 1; n++) {
      var feld = definierte_felder[felder[n]];
      if (feld)
	$scope.felder.push(feld);
    }
  }, true);

  $scope.$on('$routeUpdate', function() {
    var search = $location.search();
    if (angular.equals(search, {})) {
      search = {
	startnummer: 'yes',
	papierabnahme: 'yes',
	gruppierung: 'klasse',
	reihenfolge: 'startnummer',
	klasse: ['-'],
	feld: ['startnummer', 'name']
      };
    }
    angular.extend($scope.anzeige, von_url(search));
  });
  $scope.$emit('$routeUpdate');
}

listeController.resolve = {
  veranstaltung: function($q, $http, $route) {
    return http_request($q, $http.get('/api/veranstaltung',
				      {params: $route.current.params}));
  },
  fahrerliste: function($q, $http, $route) {
    return http_request($q, $http.get('/api/fahrerliste',
				      {params: $route.current.params}));
  },
};
