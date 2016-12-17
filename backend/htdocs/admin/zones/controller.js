'use strict;'

var zonesController = [
  '$scope', '$http', '$timeout', 'event',
  function ($scope, $http, $timeout, event) {
    $scope.$root.context(event.rankings[0].title);

    $scope.starting_classes = function() {
      var starting_classes = {};
      for (var class_ = 1; class_ <= event.classes.length; class_++) {
	var ranking_class = event.classes[class_ - 1].ranking_class;
	if (event.zones[ranking_class - 1])
	  starting_classes[ranking_class] = true;
      }
      return Object.keys(starting_classes).sort(function(a, b) { return a - b; });
    }();
    assign_event(event);

    $scope.rounds = function(class_) {
      var rounds = [];
      for (var round = 1; round <= event.classes[class_ - 1].rounds; round++)
	rounds.push(round);
      return rounds;
    };

    function assign_event(e) {
      if (e === undefined)
	$scope.skipped_zones = angular.copy($scope.old_skipped_zones);
      else {
	event = e;
	$scope.event = event;
	$scope.old_event = angular.copy(event);
	$scope.skipped_zones = skipped_zones(event);
	$scope.old_skipped_zones = angular.copy($scope.skipped_zones);
      }
    }

    function skipped_zones(event) {
      var skipped_zones = event.skipped_zones;
      var s = [];
      angular.forEach($scope.starting_classes, function(class_) {
	s[class_ - 1] = [];
	for (var round = 1; round <= event.classes[class_ - 1].rounds; round++) {
	  s[class_ - 1][round - 1] = [];
	  angular.forEach(event.zones[class_ - 1], function(zone) {
	    s[class_ - 1][round - 1][zone - 1] = false;
	  });
	}
      });

      angular.forEach(event.skipped_zones, function(zones, index) {
	var class_ = index + 1;
	if (zones && s[class_ - 1])
	  angular.forEach(zones, function(zones, index) {
	    var round = index + 1;
	    if (zones && s[class_ - 1][round - 1])
	      angular.forEach(zones, function(zone) {
		s[class_ - 1][round - 1][zone - 1] = true;
	      });
	  });
      });
      return s;
    }

    function skipped_zones(skipped_zones) {
      var k = [];
      angular.forEach(skipped_zones, function(zones, index) {
	var class_ = index + 1;
	if (zones) {
	  var r = [];
	  angular.forEach(zones, function(zones, index) {
	    var round = index + 1;
	    if (zones) {
	      var s = [];
	      angular.forEach(zones, function(zone, index) {
		if (zone)
		  s.push(index + 1);
	      });
	      if (s.length)
		r[round - 1] = s;
	    }
	  });
	  if (r.length)
	    k[class_ - 1] = r;
	}
      });
      return k;
    }

    $scope.modified = function() {
      return !(angular.equals($scope.skipped_zones, $scope.old_skipped_zones) &&
	       angular.equals($scope.event, $scope.old_event));
    };

    $scope.save = function() {
      if ($scope.busy)
	return;
      /* FIXME: Wenn Klasse schon Starter hat, muss sie weiterhin starten. (Verweis auf Starterliste.) */
      event.skipped_zones = skipped_zones($scope.skipped_zones);

      /* Wenn die Daten aus dem Trialtool importiert wurden, ist das Feature
	 skipped_zones nicht gesetzt.  Sobald eine Sektion aus der
	 Wertung genommen wird, solle s aber auf jeden Fall gesetzt werden! */
      var features = features_from_list(event);
      features.skipped_zones = true;
      event.features = features_to_list(features);
      $scope.busy = true;
      save_event($http, event.id, event).
	success(function(event) {
	  assign_event(event);
	}).
	error(network_error).
	finally(function() {
	  delete $scope.busy;
	});
    };

    $scope.discard = function() {
      if ($scope.busy)
	return;
      /* FIXME: Wenn Fahrer geladen, neu laden um Versionskonflikte aufzulösen. */
      assign_event(undefined);
    };

    $scope.keydown = function(event) {
      if (event.which == 13) {
	$timeout(function() {
	  if ($scope.modified() && $scope.form.$valid)
	    $scope.save();
	});
      } else if (event.which == 27) {
	$timeout(function() {
	  if ($scope.modified())
	    $scope.discard();
	});
      }
    };

    warn_before_unload($scope, $scope.modified);
  }];

zonesController.resolve = {
  event: [
    '$q', '$http', '$route',
    function($q, $http, $route) {
      return http_request($q, $http.get('/api/event/' + $route.current.params.id));
    }],
};