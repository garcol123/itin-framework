const journeyData = JSON.parse(document.getElementById("journey-data").textContent);
const days = journeyData.days;
const transitions = journeyData.transitions || [];
const transportPresentations = journeyData.trip.transport?.classifications || {};
const mapConfig = journeyData.trip.map || {};
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const elements = {
  mapWrap: document.querySelector(".journey-map-wrap"),
  mapContainer: document.getElementById("journey-map"),
  routeOverlay: document.getElementById("journey-route-overlay"),
  overnightStatus: document.getElementById("overnight-status"),
  overnightStatusTitle: document.getElementById("overnight-status-title"),
  overnightStatusNext: document.getElementById("overnight-status-next"),
  mapLoading: document.getElementById("map-loading"),
  mapWarning: document.getElementById("map-warning"),
  mapRecenter: document.getElementById("map-recenter"),
  tripRange: document.getElementById("trip-range"),
  tripSegments: document.getElementById("trip-segments"),
  tripTicks: document.getElementById("trip-ticks"),
  tripPosition: document.getElementById("trip-position"),
  dayRange: document.getElementById("day-range"),
  dayTicks: document.getElementById("day-ticks"),
  dayRangeTitle: document.getElementById("day-range-title"),
  dayRangeWindow: document.getElementById("day-range-window"),
  selectedRouteTitle: document.getElementById("selected-route-title"),
  journeyDetail: document.querySelector(".journey-detail"),
  dayStopViewport: document.getElementById("day-stop-viewport"),
  dayStopList: document.getElementById("day-stop-list"),
  showCurrentRow: document.getElementById("show-current-row"),
  play: document.getElementById("play-journey"),
  alternativeControl: document.getElementById("alternative-control"),
  showAlternatives: document.getElementById("show-alternatives")
};

const emptyCollection = () => ({ type: "FeatureCollection", features: [] });
const clockToMinutes = (clock) => {
  const [hour, minute] = clock.split(":").map(Number);
  return hour * 60 + minute;
};
const minutesToClock = (value) => {
  const rounded = Math.max(0, Math.round(value));
  return `${String(Math.floor(rounded / 60)).padStart(2, "0")}:${String(rounded % 60).padStart(2, "0")}`;
};
const formatDuration = (minutes) => {
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  return remainder ? `${hours}h ${remainder}m` : `${hours}h`;
};
const formatDistance = (meters) => meters < 1000 ? `${meters} m` : `${(meters / 1000).toFixed(meters >= 10_000 ? 1 : 2)} km`;
const coordinateForStop = (stop) => {
  const coordinates = stop.place.coordinates;
  return [coordinates.longitude, coordinates.latitude];
};
const exactLocation = (place) => place.private_override || ["exact", "entrance"].includes(place.coordinates.precision);
const uncertainLodging = (stop) => stop.role === "lodging_base" && !exactLocation(stop.place);
const stopMap = (day) => new Map(day.stops.map((stop) => [stop.id, stop]));
const modeLabel = (mode) => ({ walk: "Walk", rail: "Rail", bus: "🚌 Bus", taxi: "Taxi", shuttle: "Shuttle", ferry: "Ferry", flight: "Flight", local_transit: "Hotel transfer" }[mode] || mode);
const classificationClass = (classification) => classification.replaceAll("_", "-");
const railPresentations = (leg) => (leg.rail_types || []).map((classification) => transportPresentations[classification]).filter(Boolean);
const transportVisualMode = (leg) => leg.mode === "rail" && leg.rail_types?.length ? classificationClass(leg.rail_types[0]) : leg.mode === "bus" ? "bus" : null;
const presentationForVisualMode = (visualMode) => Object.entries(transportPresentations).find(([classification]) => classificationClass(classification) === visualMode)?.[1];
const emphasizedVisualMode = (visualMode) => presentationForVisualMode(visualMode)?.emphasis === true;
const transportColor = (visualMode) => presentationForVisualMode(visualMode)?.color || (visualMode === "bus" ? "#d96524" : null);
const legModeLabel = (leg) => {
  if (leg.mode !== "rail") return modeLabel(leg.mode);
  const presentations = railPresentations(leg);
  if (presentations.length === 1) return presentations[0].map_label;
  return presentations.map((presentation) => `${presentation.icon} ${presentation.short_label}`).join(" + ");
};

function buildTimelineSegments() {
  const segments = [];
  days.forEach((day, dayIndex) => {
    segments.push({ kind: "day", dayIndex, weight: 1 });
    const transition = transitions.find((candidate) => candidate.after_day === day.day);
    if (transition) {
      segments.push({ kind: "transition", transition, weight: 0.42 });
      return;
    }
    const nextDay = days[dayIndex + 1];
    if (!nextDay) return;
    const lastStop = day.stops.at(-1);
    const firstStop = nextDay.stops[0];
    if (lastStop.role === "lodging_base" && firstStop.role === "lodging_base" && lastStop.place.id === firstStop.place.id) {
      segments.push({ kind: "overnight", dayIndex, nextDayIndex: dayIndex + 1, weight: 0.08 });
    }
  });
  let cursor = 0;
  segments.forEach((segment) => {
    segment.start = cursor;
    cursor += segment.weight;
    segment.end = cursor;
  });
  return { segments, total: cursor };
}

const timeline = buildTimelineSegments();
const timelineSegments = timeline.segments;
const timelineTotal = timeline.total;
const daySegmentIndexes = new Map(timelineSegments.flatMap((segment, index) => segment.kind === "day" ? [[segment.dayIndex, index]] : []));

let selectedDayIndex = 0;
let selectedMinute = clockToMinutes(days[0].window_start);
let activeTimelineIndex = daySegmentIndexes.get(0);
let activeBoundaryFraction = 0;
let maplibregl = null;
let map = null;
let mapReady = false;
let fallbackMode = false;
let autoFollowing = true;
let lastCameraTarget = null;
let playbackFrame = null;
let playbackLastTimestamp = null;
let playbackStateKey = null;
let playbackUiTimestamp = 0;
let playbackCameraHoldUntil = 0;
let playbackStationaryTiming = null;
let reducedMotionAccumulator = 0;
let timelineScrubPointerId = null;
let resumePlaybackAfterScrub = false;
let baseMapLoaded = false;
let baseMapFailureTimer = null;
let followCurrentRow = true;
let lastRevealedEventId = null;
let displayedOvernightKey = null;

const MOVEMENT_PLAYBACK_MS = 1600;
const BUS_PLAYBACK_MS = 1900;
const FLIGHT_PLAYBACK_MS = 2600;
const OVERNIGHT_PLAYBACK_MS = 1200;
const NON_MOVEMENT_MINUTES_PER_MS = 20 / 110;
const MIN_STAY_PLAYBACK_MS = 750;
const STOP_FOCUS_ZOOM = 15;
const UNCERTAIN_STOP_FOCUS_ZOOM = 12.5;
const CAMERA_SETTLE_MS = 260;
const BASE_MAP_FAILURE_GRACE_MS = 10_000;
const PLAYBACK_UI_INTERVAL_MS = 100;
const REDUCED_MOTION_STEP_MS = 320;

elements.tripRange.min = "0";
elements.tripRange.max = String(timelineTotal);
elements.tripRange.value = "0";

function haversine(left, right) {
  const radians = Math.PI / 180;
  const lat1 = left[1] * radians;
  const lat2 = right[1] * radians;
  const deltaLat = (right[1] - left[1]) * radians;
  const deltaLon = (right[0] - left[0]) * radians;
  const value = Math.sin(deltaLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(deltaLon / 2) ** 2;
  return 6_371_000 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

function lineProgress(coordinates, fraction) {
  if (coordinates.length < 2) return { point: coordinates[0], coordinates };
  const segments = [];
  let total = 0;
  for (let index = 1; index < coordinates.length; index += 1) {
    const length = haversine(coordinates[index - 1], coordinates[index]);
    segments.push(length);
    total += length;
  }
  const target = Math.max(0, Math.min(1, fraction)) * total;
  const completed = [coordinates[0]];
  let travelled = 0;
  for (let index = 0; index < segments.length; index += 1) {
    if (travelled + segments[index] >= target) {
      const local = segments[index] === 0 ? 0 : (target - travelled) / segments[index];
      const left = coordinates[index];
      const right = coordinates[index + 1];
      const point = [left[0] + (right[0] - left[0]) * local, left[1] + (right[1] - left[1]) * local];
      completed.push(point);
      return { point, coordinates: completed };
    }
    completed.push(coordinates[index + 1]);
    travelled += segments[index];
  }
  return { point: coordinates.at(-1), coordinates };
}

function legCoordinates(day, leg) {
  if (leg.geometry?.coordinates) return leg.geometry.coordinates;
  const stops = stopMap(day);
  return [coordinateForStop(stops.get(leg.from_stop)), coordinateForStop(stops.get(leg.to_stop))];
}

const movementState = (state) => state.kind === "leg" || state.kind === "unresolved_leg";
const eventStart = (event) => event.start_time ? clockToMinutes(event.start_time) : event.end_time ? clockToMinutes(event.end_time) : null;
const eventEnd = (event) => event.end_time ? clockToMinutes(event.end_time) : event.start_time ? clockToMinutes(event.start_time) : null;
const eventDuration = (event) => {
  const start = eventStart(event);
  const end = eventEnd(event);
  return start === null || end === null ? 0 : Math.max(0, end - start);
};
const eventClockLabel = (event) => event.start_time && event.end_time
  ? `${event.start_time}–${event.end_time}`
  : event.start_time || event.end_time || event.time_label;
const activeEventsAt = (day, minute) => day.events.filter((event) => {
  if (!event.same_day) return false;
  const start = eventStart(event);
  const end = eventEnd(event);
  return start !== null && end !== null && end > start && minute >= start && minute < end;
});
const primaryEventAt = (day, minute) => activeEventsAt(day, minute)[0] || null;
const activeMealAt = (day, minute) => activeEventsAt(day, minute).find((event) => event.category === "meal") || null;
const activeMealOptionsAt = (day, minute) => activeMealAt(day, minute)?.meal_options || [];
const activeMealLocationAt = (day, state, minute) => {
  const event = activeMealAt(day, minute);
  if (!event) return null;
  const place = event.venue || event.places[0] || (!movementState(state) ? state.stop?.place : null);
  return place ? { event, place, exact: Boolean(event.venue) } : null;
};
const eventProgress = (event, minute) => {
  const duration = eventDuration(event);
  if (!duration) return { elapsed: 0, remaining: 0, remainingFraction: 0 };
  const elapsed = Math.max(0, Math.min(duration, minute - eventStart(event)));
  return { elapsed, remaining: Math.max(0, duration - elapsed), remainingFraction: Math.max(0, 1 - elapsed / duration) };
};
const stationaryEvent = (event) => !event.in_transit;
const stationaryTimerEventAt = (day, state, minute) => {
  if (!day || movementState(state)) return null;
  return activeEventsAt(day, minute).find(stationaryEvent) || null;
};
const categoryLabel = (category) => ({ transport: "Travel", meal: "Meal", visit: "Visit", logistics: "Planned stop" }[category] || category);
const mealTypeLabel = (mealType) => mealType.charAt(0).toUpperCase() + mealType.slice(1);
const eventCategoryLabel = (event) => event.category === "meal" && event.meal_type
  ? mealTypeLabel(event.meal_type)
  : categoryLabel(event.category);
const mealLocationStatus = (event) => event.category !== "meal"
  ? ""
  : event.venue ? event.meal_options.length > 1 ? "Planned + 2 backups" : "Confirmed restaurant" : `${event.meal_options.length} nearby options`;
const timerDescriptor = (event) => {
  const title = event.title.split(" · ")[0].trim();
  if (event.category !== "logistics") return title || categoryLabel(event.category);
  const wait = title.match(/\bwait for (?:the )?(bus|train|shuttle)\b/i);
  if (wait) return `Wait for ${wait[1].toLowerCase()}`;
  if (/\bforward (?:the )?(?:main )?luggage\b/i.test(title)) return "Forward luggage";
  if (/\bcollect (?:the )?(?:forwarded )?(?:main )?luggage\b|\bcollect bags\b/i.test(title)) return "Collect luggage";
  if (/\bleave bags\b/i.test(title)) return "Leave bags";
  if (/\bsecurity\b.*\bimmigration\b/i.test(title)) return "Airport formalities";
  if (/\bcheck[- ]?in\b/i.test(title)) return "Check in";
  if (/\brest\b|\brecovery\b/i.test(title)) return "Rest";
  return title || "Planned stop";
};
const timerLabel = (event) => `${timerDescriptor(event)} · ${formatDuration(eventDuration(event))}`;

function displayPoint(day, state, minute = selectedMinute) {
  if (movementState(state)) return state.point;
  const meal = activeMealLocationAt(day, state, minute);
  if (meal) return [meal.place.coordinates.longitude, meal.place.coordinates.latitude];
  const event = primaryEventAt(day, minute);
  return event?.places[0] ? [event.places[0].coordinates.longitude, event.places[0].coordinates.latitude] : state.point;
}

function visibleLocations(day, minute = selectedMinute) {
  const locations = [];
  const seen = new Set();
  const activeMeal = activeMealLocationAt(day, stateAt(day, minute), minute);
  const activeMealEvent = activeMealAt(day, minute);
  const mealVenueIds = new Set(day.events.flatMap((event) => (event.meal_options || []).map((option) => option.place.id)));
  const coincidesWithActiveMeal = (place) => activeMeal &&
    place.coordinates.longitude === activeMeal.place.coordinates.longitude &&
    place.coordinates.latitude === activeMeal.place.coordinates.latitude;
  const append = (stop) => {
    const id = stop.place.id;
    if (seen.has(id)) return;
    seen.add(id);
    locations.push(stop);
  };
  (activeMealEvent?.meal_options || []).forEach((option) => append({
    role: "meal_option",
    meal_type: activeMealEvent.meal_type,
    rank: option.rank,
    option_role: option.role,
    evidence_status: option.evidence_status,
    place: option.place
  }));
  day.stops.forEach((stop) => {
    if (!mealVenueIds.has(stop.place.id) && !coincidesWithActiveMeal(stop.place)) append(stop);
  });
  day.events.flatMap((event) => event.places).forEach((place) => {
    if (!mealVenueIds.has(place.id) && !coincidesWithActiveMeal(place)) append({ role: "activity", place });
  });
  return locations;
}

const mealMarkerStop = (stop) => stop.role === "meal_option";
const mealMarkerLabel = (stop) => `${stop.rank}. ${stop.place.name} · ${stop.option_role}`;

function stateAt(day, minute) {
  const activeLeg = day.legs.find((leg) => minute >= clockToMinutes(leg.start_time) && minute < clockToMinutes(leg.end_time));
  if (activeLeg) {
    const start = clockToMinutes(activeLeg.start_time);
    const end = clockToMinutes(activeLeg.end_time);
    const fraction = end === start ? 1 : (minute - start) / (end - start);
    if (activeLeg.status === "unresolved") {
      const coordinates = legCoordinates(day, activeLeg);
      return { kind: "unresolved_leg", leg: activeLeg, fraction, point: coordinates[0], endpoints: coordinates };
    }
    const progress = lineProgress(legCoordinates(day, activeLeg), fraction);
    return { kind: "leg", leg: activeLeg, fraction, point: progress.point, partial: progress.coordinates };
  }

  const activeStop = day.stops.find((stop) => minute >= clockToMinutes(stop.start_time) && minute < clockToMinutes(stop.end_time));
  if (activeStop) return { kind: "stop", stop: activeStop, point: coordinateForStop(activeStop) };

  const preceding = day.stops.filter((stop) => clockToMinutes(stop.end_time) <= minute).at(-1) || day.stops[0];
  return { kind: "stop", stop: preceding, point: coordinateForStop(preceding) };
}

function legDistanceMeters(leg) {
  if (leg.status === "unresolved") return null;
  if (leg.distance_meters) return leg.distance_meters;
  return leg.geometry.coordinates.slice(1).reduce(
    (total, coordinate, index) => total + haversine(leg.geometry.coordinates[index], coordinate),
    0
  );
}

function legLabel(leg) {
  if (leg.status === "unresolved") return `${legModeLabel(leg)} · route and distance TBD · ${formatDuration(leg.duration_minutes)} allowance`;
  const approximate = leg.distance_meters ? "" : "~";
  const duration = leg.duration_minutes ? formatDuration(leg.duration_minutes) : "time TBD";
  return `${legModeLabel(leg)} · ${approximate}${formatDistance(Math.round(legDistanceMeters(leg)))} · ${duration}`;
}

function legFeature(leg, properties = {}, day = null) {
  return {
    type: "Feature",
    properties: { id: leg.id, mode: leg.mode, rail_types: leg.rail_types || [], status: leg.status, geometry_kind: leg.geometry_kind, label: legLabel(leg), ...properties },
    geometry: leg.geometry || { type: "LineString", coordinates: legCoordinates(day, leg) }
  };
}

function transitionFeature(transition, properties = {}) {
  return {
    type: "Feature",
    properties: { id: transition.id, mode: "flight", status: transition.status, label: "Confirmed overnight flight", ...properties },
    geometry: transition.geometry
  };
}

function currentJourneyContext() {
  const segment = timelineSegments[activeTimelineIndex];
  if (segment.kind === "day") {
    const day = days[segment.dayIndex];
    return { segment, segmentIndex: activeTimelineIndex, day, state: stateAt(day, selectedMinute) };
  }
  if (segment.kind === "transition") {
    const progress = lineProgress(segment.transition.geometry.coordinates, activeBoundaryFraction);
    return {
      segment,
      segmentIndex: activeTimelineIndex,
      state: { kind: "transition", transition: segment.transition, fraction: activeBoundaryFraction, point: progress.point, partial: progress.coordinates }
    };
  }
  const fromDay = days[segment.dayIndex];
  const toDay = days[segment.nextDayIndex];
  const stop = fromDay.stops.at(-1);
  return {
    segment,
    segmentIndex: activeTimelineIndex,
    day: fromDay,
    state: { kind: "overnight", fromDay, toDay, stop, point: coordinateForStop(stop) }
  };
}

function progressCollections(context) {
  const upcoming = [];
  const completed = [];
  timelineSegments.forEach((segment, segmentIndex) => {
    if (segment.kind === "day") {
      const candidate = days[segment.dayIndex];
      candidate.legs.forEach((leg) => {
        const feature = legFeature(leg, { day: candidate.day }, candidate);
        if (segmentIndex < context.segmentIndex || (segmentIndex === context.segmentIndex && clockToMinutes(leg.end_time) <= selectedMinute)) completed.push(feature);
        else upcoming.push(feature);
      });
    } else if (segment.kind === "transition") {
      const feature = transitionFeature(segment.transition);
      if (segmentIndex < context.segmentIndex) completed.push(feature);
      else upcoming.push(feature);
    }
  });
  const active = context.state.kind === "leg" ? [{
    type: "Feature",
    properties: { id: context.state.leg.id, mode: context.state.leg.mode, rail_types: context.state.leg.rail_types || [] },
    geometry: { type: "LineString", coordinates: context.state.partial }
  }] : context.state.kind === "transition" ? [{
    type: "Feature",
    properties: { id: context.state.transition.id, mode: "flight" },
    geometry: { type: "LineString", coordinates: context.state.partial }
  }] : [];
  return {
    upcoming: { type: "FeatureCollection", features: upcoming },
    completed: { type: "FeatureCollection", features: completed },
    active: { type: "FeatureCollection", features: active }
  };
}

function alternativeFeatures(day) {
  if (!elements.showAlternatives.checked) return emptyCollection();
  return {
    type: "FeatureCollection",
    features: day.alternatives.flatMap((alternative) => alternative.legs.map((leg) => legFeature(leg)))
  };
}

function setSourceData(name, value) {
  const source = map?.getSource(name);
  if (source) source.setData(value);
}

function addJourneyLayers() {
  if (!map) return;
  if (!map.getSource("journey-alternatives")) map.addSource("journey-alternatives", { type: "geojson", data: emptyCollection() });

  if (!map.getLayer("journey-alternatives")) map.addLayer({
    id: "journey-alternatives", type: "line", source: "journey-alternatives",
    paint: { "line-color": "#8d651d", "line-width": 3, "line-opacity": 0.62, "line-dasharray": [1, 2] }
  });
  mapReady = true;
  elements.mapLoading.hidden = true;
  renderDay(true);
}

function applyEnglishLabels() {
  map.getStyle().layers.forEach((layer) => {
    const textField = layer.layout?.["text-field"];
    if (layer.type === "symbol" && textField && JSON.stringify(textField).includes("name")) {
      map.setLayoutProperty(layer.id, "text-field", ["coalesce", ["get", "name:en"], ["get", "name_en"], ["get", "name:latin"], ""]);
    }
  });
}

function markBaseMapLoaded() {
  baseMapLoaded = true;
  if (baseMapFailureTimer) window.clearTimeout(baseMapFailureTimer);
  baseMapFailureTimer = null;
}

function activateSvgFallback(message = "Street map unavailable. Showing the route diagram instead.") {
  if (fallbackMode) return;
  if (baseMapFailureTimer) window.clearTimeout(baseMapFailureTimer);
  baseMapFailureTimer = null;
  elements.mapWarning.textContent = message;
  if (map) map.remove();
  map = null;
  renderSvgFallback();
}

function scheduleBaseMapFailureCheck() {
  if (fallbackMode || baseMapLoaded || baseMapFailureTimer) return;
  baseMapFailureTimer = window.setTimeout(() => {
    baseMapFailureTimer = null;
    if (map?.getSource("openmaptiles") && map.isSourceLoaded("openmaptiles")) markBaseMapLoaded();
    else activateSvgFallback();
  }, BASE_MAP_FAILURE_GRACE_MS);
}

function collapseAttributionControl() {
  const control = elements.mapContainer.querySelector(".maplibregl-ctrl-attrib");
  if (!(control instanceof HTMLDetailsElement)) return;
  control.open = false;
  control.classList.remove("maplibregl-compact-show");
}

async function initializeMap() {
  try {
    maplibregl = await import(mapConfig.library_module_url);
    const initialView = mapConfig.initial_center
      ? { center: mapConfig.initial_center, zoom: mapConfig.initial_zoom ?? 4.2 }
      : { bounds: [[journeyData.fallback_extent[0], journeyData.fallback_extent[1]], [journeyData.fallback_extent[2], journeyData.fallback_extent[3]]], fitBoundsOptions: { padding: 24 } };
    map = new maplibregl.Map({
      container: elements.mapContainer,
      style: mapConfig.style_url,
      ...initialView,
      attributionControl: { compact: true },
      cooperativeGestures: true,
      renderWorldCopies: false
    });
    collapseAttributionControl();
    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "bottom-right");
    map.once("load", () => window.requestAnimationFrame(collapseAttributionControl));
    map.once("idle", () => {
      collapseAttributionControl();
      if (map.getSource("openmaptiles") && map.isSourceLoaded("openmaptiles")) markBaseMapLoaded();
      else scheduleBaseMapFailureCheck();
    });
    map.on("style.load", () => {
      window.requestAnimationFrame(collapseAttributionControl);
      applyEnglishLabels();
      addJourneyLayers();
    });
    map.on("move", renderRouteOverlay);
    map.on("resize", renderRouteOverlay);
    map.on("sourcedata", (event) => {
      if (event.sourceId === "openmaptiles" && event.isSourceLoaded) markBaseMapLoaded();
    });
    map.on("dragstart", () => suspendAutoFollow());
    map.on("zoomstart", (event) => { if (event.originalEvent) suspendAutoFollow(); });
    map.on("error", (event) => {
      if (event.sourceId === "openmaptiles") {
        if (!baseMapLoaded) scheduleBaseMapFailureCheck();
      }
      else if (mapReady) elements.mapWarning.hidden = false;
    });
    window.setTimeout(() => {
      if (!mapReady && !fallbackMode) activateSvgFallback();
    }, BASE_MAP_FAILURE_GRACE_MS);
  } catch (_error) {
    activateSvgFallback();
  }
}

function suspendAutoFollow() {
  autoFollowing = false;
  lastCameraTarget = null;
  elements.mapRecenter.hidden = false;
}

function currentDay() { return days[selectedDayIndex]; }

function routeTitle(day) {
  const names = [];
  day.stops.forEach((stop) => {
    if (names.at(-1) !== stop.place.name) names.push(stop.place.name);
  });
  if (names.length === 1) return names[0];
  const origin = names[0];
  const destination = names.at(-1);
  if (origin !== destination) return `${origin} → ${destination}`;
  const visits = names.slice(1, -1);
  return visits.length ? `${visits.join(" + ")} day route` : `${origin} day route`;
}

function renderTripTicks() {
  elements.tripTicks.replaceChildren();
  days.forEach((day, index) => {
    const segment = timelineSegments[daySegmentIndexes.get(index)];
    const tick = document.createElement("button");
    tick.type = "button";
    tick.className = "trip-tick";
    tick.setAttribute("aria-label", `Show Day ${day.day}, ${day.label}`);
    tick.title = `Day ${day.day} · ${day.label} · ${routeTitle(day)}`;
    tick.style.left = `${((segment.start + segment.weight / 2) / timelineTotal) * 100}%`;
    tick.dataset.dayIndex = String(index);
    tick.innerHTML = `<strong>${day.day}</strong>`;
    tick.addEventListener("click", () => {
      stopPlayback();
      resumeCurrentRowFollowing();
      selectedDayIndex = index;
      activeTimelineIndex = daySegmentIndexes.get(index);
      activeBoundaryFraction = 0;
      selectedMinute = clockToMinutes(day.window_start);
      autoFollowing = true;
      elements.mapRecenter.hidden = true;
      renderDay(true);
    });
    elements.tripTicks.appendChild(tick);
  });
}

function renderTripSegments() {
  elements.tripSegments.replaceChildren();
  timelineSegments.forEach((segment, index) => {
    const band = document.createElement("i");
    band.className = `trip-segment trip-segment--${segment.kind}`;
    band.dataset.segmentIndex = String(index);
    band.style.left = `${(segment.start / timelineTotal) * 100}%`;
    band.style.width = `${(segment.weight / timelineTotal) * 100}%`;
    elements.tripSegments.appendChild(band);
  });
}

function syncTripTimelineState() {
  elements.tripSegments.querySelectorAll(".trip-segment").forEach((band, index) => {
    band.classList.toggle("is-active", index === activeTimelineIndex);
  });
  const activeSegment = timelineSegments[activeTimelineIndex];
  elements.tripTicks.querySelectorAll(".trip-tick").forEach((tick) => {
    const isActive = activeSegment.kind === "day" && Number(tick.dataset.dayIndex) === selectedDayIndex;
    tick.classList.toggle("is-active", isActive);
    if (isActive) tick.setAttribute("aria-current", "step");
    else tick.removeAttribute("aria-current");
  });
}

function renderDayTicks(day) {
  elements.dayTicks.replaceChildren();
  const start = clockToMinutes(day.window_start);
  const end = clockToMinutes(day.window_end);
  const eventBoundaries = day.events.filter((event) => event.same_day).flatMap((event) => [event.start_time, event.end_time].filter(Boolean).map(clockToMinutes));
  const values = [...new Set([start, ...day.legs.map((leg) => clockToMinutes(leg.start_time)), ...eventBoundaries, end])].sort((left, right) => left - right);
  const width = elements.dayTicks.clientWidth || Math.max(1, elements.dayRange.clientWidth - 18) || 600;
  const minimumLabelGap = window.innerWidth <= 560 ? 54 : 46;
  let lastLabelPosition = -Infinity;
  values.forEach((value, index) => {
    const position = ((value - start) / Math.max(1, end - start)) * 100;
    const pixelPosition = position * width / 100;
    const roomBeforeEnd = width - pixelPosition >= minimumLabelGap;
    const showLabel = index === 0 || index === values.length - 1 || (pixelPosition - lastLabelPosition >= minimumLabelGap && roomBeforeEnd);
    const tick = document.createElement("div");
    tick.className = "day-tick";
    tick.style.left = `${position}%`;
    if (showLabel) {
      tick.innerHTML = `<span>${minutesToClock(value)}</span>`;
      lastLabelPosition = pixelPosition;
    }
    elements.dayTicks.appendChild(tick);
  });
}

function transitionIndexAfterDay(day) {
  return timelineSegments.findIndex((segment) => segment.kind === "transition" && segment.transition.after_day === day.day);
}

function focusSelectedEvent(eventId) {
  window.requestAnimationFrame(() => {
    const row = [...elements.dayStopList.children].find((candidate) => candidate.dataset.eventId === eventId);
    row?.querySelector(".itinerary-row")?.focus({ preventScroll: true });
  });
}

function focusBoundaryPoint(fraction) {
  window.requestAnimationFrame(() => {
    elements.dayStopList.querySelector(`[data-boundary-fraction="${fraction}"] .itinerary-row`)?.focus({ preventScroll: true });
  });
}

function selectItineraryEvent(day, event) {
  stopPlayback();
  followCurrentRow = true;
  autoFollowing = true;
  elements.mapRecenter.hidden = true;
  selectedDayIndex = days.findIndex((candidate) => candidate.day === day.day);

  if (!event.same_day) {
    const transitionIndex = transitionIndexAfterDay(day);
    if (transitionIndex >= 0) {
      activeTimelineIndex = transitionIndex;
      activeBoundaryFraction = 1;
      renderBoundary(true);
      focusBoundaryPoint(1);
      return;
    }
  }

  activeTimelineIndex = daySegmentIndexes.get(selectedDayIndex);
  activeBoundaryFraction = 0;
  const start = clockToMinutes(day.window_start);
  const end = clockToMinutes(day.window_end);
  const eventMinute = eventStart(event) ?? eventEnd(event) ?? start;
  selectedMinute = Math.max(start, Math.min(end, eventMinute));
  renderDay(true, false, event.id);
  focusSelectedEvent(event.id);
}

function focusMealOption(option) {
  stopPlayback();
  const coordinate = [option.place.coordinates.longitude, option.place.coordinates.latitude];
  if (mapReady && map) {
    autoFollowing = false;
    elements.mapRecenter.hidden = false;
    map[reduceMotion ? "jumpTo" : "easeTo"]({ center: coordinate, zoom: STOP_FOCUS_ZOOM, duration: reduceMotion ? 0 : 300 });
  }
}

function renderMealOptions(event) {
  const panel = document.createElement("div");
  panel.className = "map-meal-options";
  panel.setAttribute("aria-label", `${eventCategoryLabel(event)} restaurant options`);
  event.meal_options.forEach((option) => {
    const control = document.createElement("button");
    control.type = "button";
    control.className = `map-meal-option map-meal-option--${option.role}`;
    control.innerHTML = `<span class="map-meal-option__rank">${option.rank}</span><span><strong>${option.place.name}</strong><small>${option.role} · ${option.walking_minutes} min walk · ${option.evidence_status}</small><small><b>Order:</b> ${option.order_summary}</small></span>`;
    control.setAttribute("aria-label", `Focus option ${option.rank}, ${option.place.name}, ${option.role}`);
    control.addEventListener("click", () => focusMealOption(option));
    panel.appendChild(control);
  });
  return panel;
}

function renderEvents(day, preferredEventId = null) {
  elements.dayStopList.replaceChildren();
  const activeEvents = activeEventsAt(day, selectedMinute);
  const fallbackEvent = [...day.events].reverse().find((event) => {
    const start = eventStart(event);
    return event.same_day && start !== null && start <= selectedMinute;
  })
    || day.events.find((event) => event.same_day && eventStart(event) !== null);
  const preferredEvent = preferredEventId ? day.events.find((event) => event.id === preferredEventId) : null;
  const currentEvents = preferredEvent ? [preferredEvent] : activeEvents.length ? activeEvents : [fallbackEvent];
  const activeIds = new Set(currentEvents.filter(Boolean).map((event) => event.id));
  day.events.forEach((event) => {
    const item = document.createElement("li");
    const start = eventStart(event);
    const end = eventEnd(event);
    const duration = eventDuration(event);
    const isCurrent = activeIds.has(event.id);
    const isComplete = event.same_day && end !== null && selectedMinute >= end;
    item.dataset.eventId = event.id;
    if (isCurrent) {
      item.classList.add("is-current");
      item.setAttribute("aria-current", "true");
    }
    if (isComplete) item.classList.add("is-complete");
    const hasStayTimer = duration && stationaryEvent(event);
    const progress = hasStayTimer ? eventProgress(event, selectedMinute).remainingFraction : isComplete ? 0 : 1;
    const durationLabel = duration ? formatDuration(duration) : "Timed marker";
    const marker = hasStayTimer
      ? `<i aria-label="${timerDescriptor(event)} duration ${durationLabel}" class="stop-countdown stop-countdown--small" role="img" style="--timer-progress: ${progress * 360}deg"></i>`
      : '<i aria-hidden="true" class="stop-dot"></i>';
    const timingLabel = duration ? (stationaryEvent(event) ? ` <span class="event-stay-label">${timerLabel(event)}</span>` : ` · ${durationLabel}`) : "";
    const locationStatus = mealLocationStatus(event);
    const locationLabel = locationStatus
      ? ` <span class="meal-location-status meal-location-status--${event.venue ? "exact" : "flexible"}">${locationStatus}</span>`
      : "";
    const control = document.createElement("button");
    control.type = "button";
    control.className = "itinerary-row";
    control.setAttribute("aria-label", `Skip to ${eventClockLabel(event)}, ${event.title}${locationStatus ? `, ${locationStatus.toLowerCase()}` : ""}`);
    if (isCurrent) control.setAttribute("aria-current", "true");
    control.innerHTML = `<span class="stop-time">${eventClockLabel(event)}</span>${marker}<span class="stop-event"><strong>${event.title}</strong><small>${eventCategoryLabel(event)}${locationLabel}${timingLabel}</small></span>`;
    control.addEventListener("click", () => selectItineraryEvent(day, event));
    item.appendChild(control);
    if (isCurrent && event.category === "meal" && event.meal_options?.length) item.appendChild(renderMealOptions(event));
    elements.dayStopList.appendChild(item);
  });
  revealCurrentRow();
}

function currentEventRow() {
  return elements.dayStopList.querySelector(".is-current");
}

function currentRowIsVisible() {
  const row = currentEventRow();
  if (!row) return true;
  const viewportBounds = elements.dayStopViewport.getBoundingClientRect();
  const rowBounds = row.getBoundingClientRect();
  return rowBounds.top >= viewportBounds.top + 4 && rowBounds.bottom <= viewportBounds.bottom - 4;
}

function updateCurrentRowControl() {
  elements.showCurrentRow.hidden = followCurrentRow || currentRowIsVisible();
}

function revealCurrentRow(force = false) {
  const row = currentEventRow();
  if (!row) {
    elements.showCurrentRow.hidden = true;
    lastRevealedEventId = null;
    return;
  }
  if (!followCurrentRow && !force) {
    updateCurrentRowControl();
    return;
  }
  const eventId = row.dataset.eventId;
  if (!force && eventId === lastRevealedEventId && currentRowIsVisible()) return;
  lastRevealedEventId = eventId;
  const viewportBounds = elements.dayStopViewport.getBoundingClientRect();
  const rowBounds = row.getBoundingClientRect();
  if (rowBounds.top < viewportBounds.top + 6) {
    elements.dayStopViewport.scrollTop -= viewportBounds.top + 6 - rowBounds.top;
  } else if (rowBounds.bottom > viewportBounds.bottom - 6) {
    elements.dayStopViewport.scrollTop += rowBounds.bottom - viewportBounds.bottom + 6;
  }
  elements.showCurrentRow.hidden = true;
}

function suspendCurrentRowFollowing() {
  followCurrentRow = false;
  window.requestAnimationFrame(updateCurrentRowControl);
}

function resumeCurrentRowFollowing() {
  followCurrentRow = true;
  revealCurrentRow(true);
}

function updateDetail(day, preferredEventId = null) {
  elements.selectedRouteTitle.textContent = routeTitle(day);
  elements.selectedRouteTitle.title = routeTitle(day);
  renderEvents(day, preferredEventId);
}

function clearOvernightPresentation() {
  const wasOvernight = displayedOvernightKey !== null;
  displayedOvernightKey = null;
  elements.mapWrap.classList.remove("is-overnight");
  elements.journeyDetail.classList.remove("is-overnight");
  elements.overnightStatus.setAttribute("aria-hidden", "true");
  return wasOvernight;
}

function showOvernightPresentation(state) {
  const key = `${state.fromDay.day}:${state.toDay.day}`;
  const changed = displayedOvernightKey !== key;
  displayedOvernightKey = key;
  elements.mapWrap.classList.add("is-overnight");
  elements.journeyDetail.classList.add("is-overnight");
  elements.overnightStatus.setAttribute("aria-hidden", "false");
  const baseName = exactLocation(state.stop.place) ? state.stop.place.name : `${state.stop.place.name} hotel area`;
  elements.overnightStatusTitle.textContent = `Overnight at ${baseName}`;
  elements.overnightStatusNext.textContent = `Next: Day ${state.toDay.day} · ${state.toDay.label}`;
  return changed;
}

function animateDayDetailEntry() {
  if (reduceMotion || typeof elements.dayStopList.animate !== "function") return;
  elements.dayStopList.animate(
    [{ opacity: 0.55, transform: "translateY(3px)" }, { opacity: 1, transform: "translateY(0)" }],
    { duration: 280, easing: "ease-out" }
  );
}

function selectBoundaryPoint(fraction) {
  stopPlayback();
  followCurrentRow = true;
  autoFollowing = true;
  elements.mapRecenter.hidden = true;
  activeBoundaryFraction = fraction;
  renderBoundary(false);
  focusBoundaryPoint(fraction);
}

function renderBoundaryStops(items) {
  elements.showCurrentRow.hidden = true;
  lastRevealedEventId = null;
  elements.dayStopList.replaceChildren();
  items.forEach(({ time, name, fraction }) => {
    const item = document.createElement("li");
    const isCurrent = activeBoundaryFraction === fraction;
    item.dataset.boundaryFraction = String(fraction);
    if (isCurrent) {
      item.classList.add("is-current");
      item.setAttribute("aria-current", "true");
    }
    const control = document.createElement("button");
    control.type = "button";
    control.className = "itinerary-row";
    control.setAttribute("aria-label", `Skip to ${time}, ${name}`);
    if (isCurrent) control.setAttribute("aria-current", "true");
    control.innerHTML = `<span class="stop-time">${time}</span><i aria-hidden="true" class="stop-dot"></i><span class="stop-event"><strong>${name}</strong><small>Flight endpoint</small></span>`;
    control.addEventListener("click", () => selectBoundaryPoint(fraction));
    item.appendChild(control);
    elements.dayStopList.appendChild(item);
  });
}

function updateBoundaryDetail(context) {
  const state = context.state;
  elements.alternativeControl.hidden = true;
  elements.showAlternatives.checked = false;
  elements.dayRange.disabled = true;

  if (state.kind === "transition") {
    clearOvernightPresentation();
    const transition = state.transition;
    const booking = transition.booking;
    elements.selectedRouteTitle.textContent = `${transition.from_place.name} → ${transition.to_place.name}`;
    elements.selectedRouteTitle.title = elements.selectedRouteTitle.textContent;
    elements.dayRangeTitle.textContent = "Cross-day flight";
    elements.dayRangeWindow.textContent = booking.date_label;
    renderBoundaryStops([
      { time: booking.departure_time, name: transition.from_place.name, fraction: 0 },
      { time: booking.arrival_time, name: transition.to_place.name, fraction: 1 }
    ]);
  } else {
    selectedDayIndex = context.segment.dayIndex;
    selectedMinute = clockToMinutes(state.fromDay.window_end);
    if (showOvernightPresentation(state)) {
      elements.dayRange.min = String(clockToMinutes(state.fromDay.window_start));
      elements.dayRange.max = String(selectedMinute);
      renderDayTicks(state.fromDay);
      updateDetail(state.fromDay);
    }
    elements.dayRange.value = String(selectedMinute);
    elements.dayRangeTitle.textContent = `Day ${state.fromDay.day} complete`;
    elements.dayRangeWindow.textContent = `Overnight → Day ${state.toDay.day}`;
  }
}

function fitBoundary(context, moveToOvernight = false) {
  if (!mapReady || !autoFollowing) return;
  if (context.state.kind === "overnight") {
    if (!moveToOvernight) return;
    lastCameraTarget = `${context.segment.kind}:${context.segmentIndex}`;
    const zoom = Math.max(map.getZoom(), 13);
    map[reduceMotion ? "jumpTo" : "easeTo"]({ center: context.state.point, zoom, duration: reduceMotion ? 0 : 300 });
    return;
  }
  lastCameraTarget = `${context.segment.kind}:${context.segmentIndex}`;
  map.fitBounds(boundsForCoordinates(context.state.transition.geometry.coordinates), { padding: 70, maxZoom: 4, duration: reduceMotion ? 0 : 500, linear: true });
}

function renderBoundary(fit = true) {
  const context = currentJourneyContext();
  updateBoundaryDetail(context);
  syncTripRange();
  if (mapReady) {
    renderRouteOverlay();
    if (fit) fitBoundary(context);
  } else if (fallbackMode && context.state.kind !== "overnight") {
    renderSvgFallback();
  }
}

function updateMapData(day, state) {
  setSourceData("journey-alternatives", alternativeFeatures(day));
  renderRouteOverlay();
}

function markerVariant(state) {
  if (state.kind === "transition") return "schematic";
  if (state.kind === "leg" && (state.leg.geometry_kind === "schematic" || state.leg.status !== "verified")) return "schematic";
  return "verified";
}

function renderRouteOverlay() {
  if (!map || !mapReady || fallbackMode) return;
  const context = currentJourneyContext();
  const day = context.day;
  const state = context.state;
  const progress = progressCollections(context);
  const width = elements.mapContainer.clientWidth;
  const height = elements.mapContainer.clientHeight;
  if (!width || !height) return;
  elements.routeOverlay.hidden = false;

  const namespace = "http://www.w3.org/2000/svg";
  const create = (name, className) => {
    const node = document.createElementNS(namespace, name);
    if (className) node.setAttribute("class", className);
    return node;
  };
  const project = (coordinate) => map.project(coordinate);
  const appendLine = (feature, className) => {
    const points = feature.geometry.coordinates.map(project);
    const xs = points.map((point) => point.x);
    const ys = points.map((point) => point.y);
    if (Math.max(...xs) < -120 || Math.min(...xs) > width + 120 || Math.max(...ys) < -120 || Math.min(...ys) > height + 120) return;
    const unresolved = feature.properties.status === "unresolved" ? " trail-unresolved" : "";
    const visualMode = transportVisualMode(feature.properties);
    const modeClass = visualMode ? ` trail-${visualMode}` : "";
    const line = create("polyline", `${className}${unresolved}${modeClass}`);
    line.setAttribute("points", points.map((point) => `${point.x},${point.y}`).join(" "));
    elements.routeOverlay.appendChild(line);
  };

  elements.routeOverlay.setAttribute("viewBox", `0 0 ${width} ${height}`);
  elements.routeOverlay.replaceChildren();
  progress.upcoming.features.forEach((feature) => appendLine(feature, "trail-upcoming"));
  progress.completed.features.forEach((feature) => appendLine(feature, "trail-travelled"));
  progress.active.features.forEach((feature) => appendLine(feature, "trail-active"));

  (day?.legs || []).forEach((leg, index) => {
    const point = project(lineProgress(legCoordinates(day, leg), index % 2 === 0 ? 0.38 : 0.62).point);
    if (point.x < -100 || point.x > width + 100 || point.y < -40 || point.y > height + 40) return;
    const visualMode = transportVisualMode(leg);
    const label = create("text", visualMode ? `trail-label trail-label--${visualMode}` : "trail-label");
    label.setAttribute("x", point.x);
    label.setAttribute("y", point.y - 8);
    label.textContent = legLabel(leg);
    elements.routeOverlay.appendChild(label);
  });

  if (state.kind === "transition") {
    const point = project(lineProgress(state.transition.geometry.coordinates, 0.5).point);
    const label = create("text", "trail-label");
    label.setAttribute("x", point.x);
    label.setAttribute("y", point.y - 8);
    label.textContent = "Confirmed overnight flight";
    elements.routeOverlay.appendChild(label);
  }

  const visibleStops = day ? visibleLocations(day) : (state.kind === "transition" ? [
    { role: "activity", place: state.transition.from_place },
    { role: "activity", place: state.transition.to_place }
  ] : [{ role: "lodging_base", place: state.fromDay.stops.at(-1).place }]);
  visibleStops.forEach((stop) => {
    const point = project(coordinateForStop(stop));
    const uncertainBase = uncertainLodging(stop);
    const mealStop = mealMarkerStop(stop);
    const circleClass = mealStop
      ? `trail-stop trail-stop--meal-option trail-stop--meal-${stop.option_role}${stop.evidence_status === "provisional" ? " trail-stop--meal-provisional" : ""}`
      : uncertainBase ? "trail-stop trail-stop--uncertain" : "trail-stop";
    const circle = create("circle", circleClass);
    circle.setAttribute("cx", point.x);
    circle.setAttribute("cy", point.y);
    circle.setAttribute("r", mealStop ? "11" : uncertainBase ? "15" : "5");
    elements.routeOverlay.appendChild(circle);
    if (mealStop) {
      const glyph = create("text", "trail-meal-glyph");
      glyph.setAttribute("x", point.x);
      glyph.setAttribute("y", point.y + 4);
      glyph.textContent = String(stop.rank);
      elements.routeOverlay.appendChild(glyph);
    }
    const labelClass = mealStop ? `trail-stop-label trail-stop-label--meal trail-stop-label--meal-${stop.option_role}` : "trail-stop-label";
    const label = create("text", labelClass);
    label.setAttribute("x", point.x + (mealStop ? 16 : 8));
    label.setAttribute("y", point.y - (mealStop ? 12 : 8));
    label.textContent = mealStop
      ? mealMarkerLabel(stop)
      : uncertainBase ? `${stop.place.name} hotel area · location TBD` : stop.place.name;
    elements.routeOverlay.appendChild(label);
  });

  if (state.kind === "unresolved_leg") {
    const endpointPoints = state.endpoints.map(project);
    const transfer = create("polyline", "trail-tbd-progress");
    transfer.setAttribute("points", endpointPoints.map((point) => `${point.x},${point.y}`).join(" "));
    transfer.setAttribute("stroke-dashoffset", String(-state.fraction * 36));
    elements.routeOverlay.appendChild(transfer);

    endpointPoints.forEach((point, index) => {
      const endpoint = create("circle", `trail-transfer-endpoint trail-transfer-endpoint--${index === 0 ? "origin" : "destination"}`);
      endpoint.setAttribute("cx", point.x);
      endpoint.setAttribute("cy", point.y);
      endpoint.setAttribute("r", "10");
      endpoint.setAttribute("opacity", String(index === 0 ? 1 - state.fraction * 0.7 : 0.3 + state.fraction * 0.7));
      elements.routeOverlay.appendChild(endpoint);
    });
  } else {
    const timerEvent = stationaryTimerEventAt(day, state, selectedMinute);
    const timer = timerEvent && eventDuration(timerEvent) ? eventProgress(timerEvent, selectedMinute) : null;
    const position = project(day ? displayPoint(day, state) : state.point);
    if (timer) {
      const timerTrack = create("circle", "trail-stop-timer-track");
      timerTrack.setAttribute("cx", position.x);
      timerTrack.setAttribute("cy", position.y);
      timerTrack.setAttribute("r", "16");
      elements.routeOverlay.appendChild(timerTrack);
      const timerProgress = create("circle", "trail-stop-timer-progress");
      timerProgress.setAttribute("cx", position.x);
      timerProgress.setAttribute("cy", position.y);
      timerProgress.setAttribute("r", "16");
      timerProgress.setAttribute("pathLength", "100");
      timerProgress.setAttribute("stroke-dasharray", "100");
      timerProgress.setAttribute("stroke-dashoffset", String(100 * (1 - timer.remainingFraction)));
      elements.routeOverlay.appendChild(timerProgress);
      const timerText = create("text", "trail-stop-duration-label");
      timerText.setAttribute("x", position.x + 22);
      timerText.setAttribute("y", position.y + 20);
      timerText.textContent = timerLabel(timerEvent);
      elements.routeOverlay.appendChild(timerText);
    }
    const activeMeal = day ? activeMealLocationAt(day, state, selectedMinute) : null;
    const visualMode = state.kind === "leg" ? transportVisualMode(state.leg) : null;
    const modeClass = visualMode ? ` trail-position--${visualMode}` : "";
    const mealClass = activeMeal ? ` trail-position--${activeMeal.exact ? "meal" : "meal-area"}` : "";
    const current = create("circle", `trail-position trail-position--${markerVariant(state)}${modeClass}${mealClass}`);
    current.setAttribute("cx", position.x);
    current.setAttribute("cy", position.y);
    current.setAttribute("r", activeMeal ? "15" : emphasizedVisualMode(visualMode) ? "10" : "8");
    elements.routeOverlay.appendChild(current);
  }
}

function updateMotionOverlay(context) {
  if (fallbackMode && !mapReady) {
    if (context.state.kind === "overnight") return;
    renderSvgFallback();
    return;
  }
  if (!mapReady || !map) return;
  const state = context.state;
  const project = (coordinate) => map.project(coordinate);

  if (state.kind === "leg" || state.kind === "transition") {
    const active = elements.routeOverlay.querySelector(".trail-active");
    if (active) {
      const coordinates = state.partial;
      active.setAttribute("points", coordinates.map(project).map((point) => `${point.x},${point.y}`).join(" "));
    }
  }

  if (state.kind === "unresolved_leg") {
    const transfer = elements.routeOverlay.querySelector(".trail-tbd-progress");
    if (transfer) transfer.setAttribute("stroke-dashoffset", String(-state.fraction * 36));
    const origin = elements.routeOverlay.querySelector(".trail-transfer-endpoint--origin");
    const destination = elements.routeOverlay.querySelector(".trail-transfer-endpoint--destination");
    if (origin) origin.setAttribute("opacity", String(1 - state.fraction * 0.7));
    if (destination) destination.setAttribute("opacity", String(0.3 + state.fraction * 0.7));
    return;
  }

  const current = elements.routeOverlay.querySelector(".trail-position");
  if (!current) return;
  const day = context.day;
  const position = project(day ? displayPoint(day, state) : state.point);
  current.setAttribute("cx", position.x);
  current.setAttribute("cy", position.y);
  const activeMeal = day ? activeMealLocationAt(day, state, selectedMinute) : null;
  const visualMode = state.kind === "leg" ? transportVisualMode(state.leg) : null;
  const modeClass = visualMode ? ` trail-position--${visualMode}` : "";
  const mealClass = activeMeal ? ` trail-position--${activeMeal.exact ? "meal" : "meal-area"}` : "";
  current.setAttribute("class", `trail-position trail-position--${markerVariant(state)}${modeClass}${mealClass}`);
  current.setAttribute("r", activeMeal ? "15" : emphasizedVisualMode(visualMode) ? "10" : "8");
  const timerEvent = stationaryTimerEventAt(day, state, selectedMinute);
  const timer = timerEvent && eventDuration(timerEvent) ? eventProgress(timerEvent, selectedMinute) : null;
  const timerRings = elements.routeOverlay.querySelectorAll(".trail-stop-timer-track, .trail-stop-timer-progress, .trail-stop-duration-label");
  if (!timer) {
    timerRings.forEach((ring) => ring.remove());
    return;
  }
  timerRings.forEach((ring) => {
    if (ring.tagName.toLowerCase() === "text") {
      ring.setAttribute("x", position.x + 22);
      ring.setAttribute("y", position.y + 20);
    } else {
      ring.setAttribute("cx", position.x);
      ring.setAttribute("cy", position.y);
    }
  });
  const timerRing = elements.routeOverlay.querySelector(".trail-stop-timer-progress");
  if (timerRing && timer) timerRing.setAttribute("stroke-dashoffset", String(100 * (1 - timer.remainingFraction)));
}

function boundsForCoordinates(coordinates) {
  const bounds = new maplibregl.LngLatBounds();
  coordinates.forEach((coordinate) => bounds.extend(coordinate));
  return bounds;
}

function stationaryFocus(day, state) {
  const meal = activeMealLocationAt(day, state, selectedMinute);
  const event = primaryEventAt(day, selectedMinute);
  return {
    point: displayPoint(day, state),
    place: meal?.place || event?.places[0] || state.stop.place
  };
}

function cameraTargetKey(day, state) {
  if (movementState(state)) return `${state.kind}:${state.leg.id}`;
  const meal = activeMealAt(day, selectedMinute);
  if (meal?.meal_options?.length > 1) return `meal-options:${meal.id}`;
  const { point } = stationaryFocus(day, state);
  return `stop:${point.map((value) => value.toFixed(5)).join(":")}`;
}

function fitCurrentState(state, force = false) {
  if (!mapReady || !autoFollowing) return false;
  const day = currentDay();
  const target = cameraTargetKey(day, state);
  if (!force && target === lastCameraTarget) return false;
  lastCameraTarget = target;
  if (movementState(state)) {
    const maxZoom = state.leg.mode === "walk" ? 17 : state.leg.mode === "flight" ? 5 : 12;
    map.fitBounds(boundsForCoordinates(legCoordinates(day, state.leg)), { padding: 70, maxZoom, duration: reduceMotion ? 0 : 240, linear: true });
    return true;
  }
  const mealOptions = activeMealOptionsAt(day, selectedMinute);
  if (mealOptions.length > 1) {
    map.fitBounds(boundsForCoordinates(mealOptions.map((option) => [option.place.coordinates.longitude, option.place.coordinates.latitude])), { padding: 90, maxZoom: 16, duration: reduceMotion ? 0 : 300, linear: true });
    return true;
  }
  const { point, place } = stationaryFocus(day, state);
  const zoom = exactLocation(place) ? STOP_FOCUS_ZOOM : UNCERTAIN_STOP_FOCUS_ZOOM;
  map[reduceMotion ? "jumpTo" : "easeTo"]({ center: point, zoom, duration: reduceMotion ? 0 : 300 });
  return true;
}

function recenterRoute() {
  autoFollowing = true;
  elements.mapRecenter.hidden = true;
  const segment = timelineSegments[activeTimelineIndex];
  if (segment.kind === "day") {
    const state = renderMinute(false);
    fitCurrentState(state, true);
  } else {
    fitBoundary(currentJourneyContext(), true);
  }
}

function dayProgressFraction(day, minute = selectedMinute) {
  const start = clockToMinutes(day.window_start);
  const end = clockToMinutes(day.window_end);
  return Math.max(0, Math.min(1, (minute - start) / Math.max(1, end - start)));
}

function syncTripRange() {
  const segment = timelineSegments[activeTimelineIndex];
  if (segment.kind === "day") {
    const day = currentDay();
    elements.tripRange.value = String(segment.start + segment.weight * dayProgressFraction(day));
    elements.tripPosition.textContent = `Day ${day.day} of ${days.length} · ${day.label} · ${minutesToClock(selectedMinute)}`;
    elements.tripRange.setAttribute("aria-valuetext", `Day ${day.day} of ${days.length}, ${day.label}, ${minutesToClock(selectedMinute)}`);
  } else if (segment.kind === "transition") {
    elements.tripRange.value = String(segment.start + segment.weight * activeBoundaryFraction);
    elements.tripPosition.textContent = segment.transition.before_day ? `Flight to Day ${segment.transition.before_day}` : `Return flight to ${segment.transition.to_place.name}`;
    elements.tripRange.setAttribute("aria-valuetext", `${elements.tripPosition.textContent}, ${Math.round(activeBoundaryFraction * 100)} percent`);
  } else {
    elements.tripRange.value = String(segment.start + segment.weight * activeBoundaryFraction);
    elements.tripPosition.textContent = `Overnight · Day ${days[segment.dayIndex].day} to Day ${days[segment.nextDayIndex].day}`;
    elements.tripRange.setAttribute("aria-valuetext", `${elements.tripPosition.textContent}, ${Math.round(activeBoundaryFraction * 100)} percent`);
  }
  syncTripTimelineState();
}

function tripPositionForValue(value) {
  const bounded = Math.max(0, Math.min(timelineTotal, value));
  let segmentIndex = timelineSegments.findIndex((segment, index) => bounded < segment.end || index === timelineSegments.length - 1);
  if (segmentIndex < 0) segmentIndex = timelineSegments.length - 1;
  const segment = timelineSegments[segmentIndex];
  const fraction = Math.max(0, Math.min(1, (bounded - segment.start) / segment.weight));
  if (segment.kind !== "day") return { kind: segment.kind, segmentIndex, fraction };
  const day = days[segment.dayIndex];
  const start = clockToMinutes(day.window_start);
  const end = clockToMinutes(day.window_end);
  return { kind: "day", segmentIndex, dayIndex: segment.dayIndex, minute: start + fraction * (end - start) };
}

function renderMinute(fitActive = false, preferredEventId = null) {
  const day = currentDay();
  const state = stateAt(day, selectedMinute);
  elements.dayRange.value = String(selectedMinute);
  syncTripRange();
  updateDetail(day, preferredEventId);
  if (mapReady) updateMapData(day, state);
  else if (fallbackMode) renderSvgFallback();
  if (fitActive) fitCurrentState(state);
  return state;
}

function renderDay(fit = true, resetToStart = false, preferredEventId = null) {
  const day = currentDay();
  const leavingOvernight = clearOvernightPresentation();
  elements.dayRange.disabled = false;
  if (resetToStart) selectedMinute = clockToMinutes(day.window_start);
  elements.dayRange.min = String(clockToMinutes(day.window_start));
  elements.dayRange.max = String(clockToMinutes(day.window_end));
  elements.dayRange.value = String(selectedMinute);
  elements.dayRangeTitle.textContent = `Day ${day.day} timeline`;
  elements.dayRangeWindow.textContent = `${day.window_start}–${day.window_end}`;
  elements.alternativeControl.hidden = day.alternatives.length === 0;
  elements.showAlternatives.checked = false;
  renderDayTicks(day);
  lastCameraTarget = null;
  const state = renderMinute(false, preferredEventId);
  if (leavingOvernight) animateDayDetailEntry();
  if (mapReady) {
    updateMapData(day, state);
    if (fit) fitCurrentState(state);
  } else if (fallbackMode) {
    renderSvgFallback();
  }
}

function stopPlayback() {
  if (playbackFrame) window.cancelAnimationFrame(playbackFrame);
  playbackFrame = null;
  playbackLastTimestamp = null;
  playbackStateKey = null;
  playbackCameraHoldUntil = 0;
  playbackStationaryTiming = null;
  reducedMotionAccumulator = 0;
  elements.play.textContent = "Play trip";
  elements.play.setAttribute("aria-pressed", "false");
}

function playbackKey(segment, state) {
  if (segment.kind === "transition") return `transition:${segment.transition.id}`;
  if (segment.kind === "overnight") return `overnight:${segment.dayIndex}`;
  if (movementState(state)) return `${state.kind}:${state.leg.id}`;
  const eventIds = activeEventsAt(currentDay(), selectedMinute).map((event) => event.id).join(",");
  return `stop:${state.stop.id}:events:${eventIds}`;
}

function nextDayBoundary(day, minute) {
  const boundaries = [
    clockToMinutes(day.window_end),
    ...day.legs.flatMap((leg) => [clockToMinutes(leg.start_time), clockToMinutes(leg.end_time)]),
    ...day.stops.flatMap((stop) => [clockToMinutes(stop.start_time), clockToMinutes(stop.end_time)]),
    ...day.events.filter((event) => event.same_day).flatMap((event) => [event.start_time, event.end_time].filter(Boolean).map(clockToMinutes))
  ].filter((value) => value > minute + 0.0001);
  return Math.min(...boundaries);
}

function stationaryPlaybackTiming(day, state) {
  const timerEvent = stationaryTimerEventAt(day, state, selectedMinute);
  if (!timerEvent) return null;
  const endMinute = nextDayBoundary(day, selectedMinute);
  const minuteSpan = endMinute - selectedMinute;
  const naturalDurationMs = minuteSpan / NON_MOVEMENT_MINUTES_PER_MS;
  return {
    startMinute: selectedMinute,
    endMinute,
    elapsedMs: 0,
    durationMs: Math.max(MIN_STAY_PLAYBACK_MS, naturalDurationMs)
  };
}

function advanceTimelineSegment(timestamp) {
  if (activeTimelineIndex >= timelineSegments.length - 1) {
    stopPlayback();
    return false;
  }
  activeTimelineIndex += 1;
  activeBoundaryFraction = 0;
  playbackStateKey = null;
  playbackCameraHoldUntil = 0;
  playbackStationaryTiming = null;
  reducedMotionAccumulator = 0;
  const next = timelineSegments[activeTimelineIndex];
  if (next.kind === "day") {
    selectedDayIndex = next.dayIndex;
    selectedMinute = clockToMinutes(currentDay().window_start);
    renderDay(true);
    if (mapReady && autoFollowing && !reduceMotion) playbackCameraHoldUntil = timestamp + 480;
  } else {
    renderBoundary(true);
    if (next.kind === "transition" && mapReady && autoFollowing && !reduceMotion) playbackCameraHoldUntil = timestamp + 520;
  }
  return true;
}

function renderPlaybackProgress(timestamp, forceDetail = false) {
  const context = currentJourneyContext();
  if (context.segment.kind === "day") {
    elements.dayRange.value = String(selectedMinute);
    syncTripRange();
    if (forceDetail || timestamp - playbackUiTimestamp >= PLAYBACK_UI_INTERVAL_MS) {
      updateDetail(context.day);
      playbackUiTimestamp = timestamp;
    }
  } else {
    syncTripRange();
    if (forceDetail || timestamp - playbackUiTimestamp >= PLAYBACK_UI_INTERVAL_MS) {
      updateBoundaryDetail(context);
      playbackUiTimestamp = timestamp;
    }
  }
  updateMotionOverlay(context);
}

function reducedMotionAdvance(segment, state, delta) {
  reducedMotionAccumulator += delta;
  const readableStay = segment.kind === "day" && stationaryTimerEventAt(currentDay(), state, selectedMinute);
  const stepDuration = readableStay ? MIN_STAY_PLAYBACK_MS : REDUCED_MOTION_STEP_MS;
  if (reducedMotionAccumulator < stepDuration) return false;
  reducedMotionAccumulator = 0;
  if (segment.kind === "transition" || segment.kind === "overnight") {
    activeBoundaryFraction = 1;
  } else if (movementState(state)) {
    selectedMinute = clockToMinutes(state.leg.end_time);
  } else {
    selectedMinute = nextDayBoundary(currentDay(), selectedMinute);
  }
  return true;
}

function playbackTick(timestamp) {
  if (!playbackFrame) return;
  if (playbackLastTimestamp === null) playbackLastTimestamp = timestamp;
  const delta = Math.min(100, Math.max(0, timestamp - playbackLastTimestamp));
  playbackLastTimestamp = timestamp;
  const segment = timelineSegments[activeTimelineIndex];

  if (segment.kind !== "day") {
    const context = currentJourneyContext();
    const key = playbackKey(segment, context.state);
    if (key !== playbackStateKey) {
      playbackStateKey = key;
      renderBoundary(false);
      playbackUiTimestamp = timestamp;
    }
    if (timestamp >= playbackCameraHoldUntil) {
      if (reduceMotion) {
        reducedMotionAdvance(segment, context.state, delta);
      } else {
        const duration = segment.kind === "transition" ? FLIGHT_PLAYBACK_MS : OVERNIGHT_PLAYBACK_MS;
        activeBoundaryFraction = Math.min(1, activeBoundaryFraction + delta / duration);
      }
      renderPlaybackProgress(timestamp);
    }
    if (activeBoundaryFraction >= 1) {
      renderPlaybackProgress(timestamp, true);
      if (!advanceTimelineSegment(timestamp)) return;
    }
    playbackFrame = window.requestAnimationFrame(playbackTick);
    return;
  }

  const day = currentDay();
  const dayEnd = clockToMinutes(day.window_end);
  if (selectedMinute >= dayEnd) {
    if (!advanceTimelineSegment(timestamp)) return;
    playbackFrame = window.requestAnimationFrame(playbackTick);
    return;
  }

  const state = stateAt(day, selectedMinute);
  const key = playbackKey(segment, state);
  if (key !== playbackStateKey) {
    playbackStateKey = key;
    playbackStationaryTiming = stationaryPlaybackTiming(day, state);
    renderMinute(false);
    playbackUiTimestamp = timestamp;
    if (fitCurrentState(state)) {
      if (mapReady && autoFollowing && !reduceMotion) playbackCameraHoldUntil = timestamp + CAMERA_SETTLE_MS;
    }
  }

  if (timestamp >= playbackCameraHoldUntil) {
    if (reduceMotion) {
      reducedMotionAdvance(segment, state, delta);
    } else if (movementState(state)) {
      const start = clockToMinutes(state.leg.start_time);
      const end = clockToMinutes(state.leg.end_time);
      const presentation = presentationForVisualMode(transportVisualMode(state.leg));
      const playbackDuration = presentation
        ? presentation.playback_ms
        : transportVisualMode(state.leg) === "bus"
        ? BUS_PLAYBACK_MS
        : MOVEMENT_PLAYBACK_MS;
      selectedMinute = Math.min(end, selectedMinute + delta * (end - start) / playbackDuration);
    } else if (playbackStationaryTiming) {
      playbackStationaryTiming.elapsedMs = Math.min(
        playbackStationaryTiming.durationMs,
        playbackStationaryTiming.elapsedMs + delta
      );
      const fraction = playbackStationaryTiming.elapsedMs / playbackStationaryTiming.durationMs;
      selectedMinute = playbackStationaryTiming.startMinute
        + fraction * (playbackStationaryTiming.endMinute - playbackStationaryTiming.startMinute);
    } else {
      const boundary = nextDayBoundary(day, selectedMinute);
      selectedMinute = Math.min(boundary, selectedMinute + delta * NON_MOVEMENT_MINUTES_PER_MS);
    }
    const nextState = stateAt(day, selectedMinute);
    if (playbackKey(segment, nextState) === playbackStateKey) {
      renderPlaybackProgress(timestamp);
    } else {
      playbackStateKey = null;
      playbackStationaryTiming = null;
      renderMinute(false);
      playbackUiTimestamp = timestamp;
    }
  }

  playbackFrame = window.requestAnimationFrame(playbackTick);
}

function startPlayback() {
  const activeSegment = timelineSegments[activeTimelineIndex];
  if (activeTimelineIndex === timelineSegments.length - 1 && activeSegment.kind === "transition" && activeBoundaryFraction >= 1) {
    selectedDayIndex = 0;
    selectedMinute = clockToMinutes(days[0].window_start);
    activeTimelineIndex = daySegmentIndexes.get(0);
    activeBoundaryFraction = 0;
    renderDay(true);
  }
  recenterRoute();
  elements.play.textContent = "Pause trip";
  elements.play.setAttribute("aria-pressed", "true");
  playbackLastTimestamp = null;
  playbackStateKey = null;
  playbackStationaryTiming = null;
  playbackUiTimestamp = 0;
  reducedMotionAccumulator = 0;
  playbackFrame = window.requestAnimationFrame(playbackTick);
}

function beginTimelineScrub(event) {
  if (timelineScrubPointerId !== null || (event.pointerType === "mouse" && event.button !== 0)) return;
  timelineScrubPointerId = event.pointerId;
  resumePlaybackAfterScrub = Boolean(playbackFrame);
  if (resumePlaybackAfterScrub) stopPlayback();
}

function endTimelineScrub(event) {
  if (event.pointerId !== timelineScrubPointerId) return;
  timelineScrubPointerId = null;
  const shouldResume = resumePlaybackAfterScrub;
  resumePlaybackAfterScrub = false;
  if (shouldResume && !playbackFrame) startPlayback();
}

function followScrubCamera(previousSegmentIndex) {
  if (!mapReady || !autoFollowing) return;
  const context = currentJourneyContext();
  const segmentChanged = context.segmentIndex !== previousSegmentIndex;
  if (context.segment.kind !== "day") {
    const adjacentSegment = Math.abs(context.segmentIndex - previousSegmentIndex) === 1;
    if (segmentChanged) fitBoundary(context, !adjacentSegment);
    return;
  }
  fitCurrentState(context.state);
}

function fallbackViewportCoordinates(context) {
  if (!context.day) return context.state.kind === "transition" ? context.state.transition.geometry.coordinates : [context.state.point];
  if (movementState(context.state)) return legCoordinates(context.day, context.state.leg);
  const mealOptions = activeMealOptionsAt(context.day, selectedMinute);
  if (mealOptions.length > 1) return mealOptions.map((option) => [option.place.coordinates.longitude, option.place.coordinates.latitude]);
  const { point, place } = stationaryFocus(context.day, context.state);
  const radius = exactLocation(place) ? 0.012 : 0.05;
  return [
    [point[0] - radius, point[1] - radius],
    [point[0] + radius, point[1] + radius]
  ];
}

function renderSvgFallback() {
  fallbackMode = true;
  mapReady = false;
  elements.routeOverlay.hidden = true;
  elements.routeOverlay.replaceChildren();
  elements.mapLoading.hidden = true;
  elements.mapWarning.hidden = false;
  const context = currentJourneyContext();
  const day = context.day;
  const state = context.state;
  const width = Math.max(320, elements.mapContainer.clientWidth);
  const height = Math.max(360, elements.mapContainer.clientHeight);
  const coordinates = fallbackViewportCoordinates(context);
  const longitudes = coordinates.map((coordinate) => coordinate[0]);
  const latitudes = coordinates.map((coordinate) => coordinate[1]);
  let minLon = Math.min(...longitudes);
  let maxLon = Math.max(...longitudes);
  let minLat = Math.min(...latitudes);
  let maxLat = Math.max(...latitudes);
  if (minLon === maxLon) { minLon -= 0.1; maxLon += 0.1; }
  if (minLat === maxLat) { minLat -= 0.1; maxLat += 0.1; }
  const lonPad = (maxLon - minLon) * 0.15;
  const latPad = (maxLat - minLat) * 0.15;
  minLon -= lonPad; maxLon += lonPad; minLat -= latPad; maxLat += latPad;
  const project = ([longitude, latitude]) => [38 + ((longitude - minLon) / (maxLon - minLon)) * (width - 76), 38 + ((maxLat - latitude) / (maxLat - minLat)) * (height - 76)];
  const namespace = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(namespace, "svg");
  svg.classList.add("journey-fallback");
  svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", day ? `Fallback route map for day ${day.day}` : state.kind === "transition" ? "Fallback route map for confirmed flight" : "Fallback overnight lodging location");
  (day?.legs || []).forEach((leg) => {
    const coordinates = legCoordinates(day, leg);
    const path = document.createElementNS(namespace, "polyline");
    const visualMode = transportVisualMode(leg);
    if (visualMode) path.classList.add(`trail-${visualMode}`);
    path.setAttribute("points", coordinates.map(project).map((point) => point.join(",")).join(" "));
    path.setAttribute("fill", "none");
    const modeStroke = transportColor(visualMode);
    path.setAttribute("stroke", modeStroke || (clockToMinutes(leg.end_time) < selectedMinute ? "#245f73" : "#a96b42"));
    path.setAttribute("stroke-width", visualMode ? "6" : leg.mode === "walk" ? "5" : "3");
    if (leg.status === "unresolved") path.setAttribute("stroke-dasharray", "7 6");
    svg.appendChild(path);

    const [labelX, labelY] = project(lineProgress(coordinates, 0.5).point);
    const label = document.createElementNS(namespace, "text");
    label.setAttribute("x", labelX);
    label.setAttribute("y", labelY - 7);
    label.setAttribute("text-anchor", "middle");
    label.setAttribute("paint-order", "stroke");
    label.setAttribute("stroke", "#fffefb");
    label.setAttribute("stroke-width", "4");
    label.setAttribute("fill", "#111111");
    label.setAttribute("font-size", "11");
    label.textContent = legLabel(leg);
    svg.appendChild(label);
  });
  if (state.kind === "transition") {
    const path = document.createElementNS(namespace, "polyline");
    path.setAttribute("points", state.transition.geometry.coordinates.map(project).map((point) => point.join(",")).join(" "));
    path.setAttribute("fill", "none");
    path.setAttribute("stroke", "#a96b42");
    path.setAttribute("stroke-width", "4");
    svg.appendChild(path);
    const travelled = document.createElementNS(namespace, "polyline");
    travelled.setAttribute("points", state.partial.map(project).map((point) => point.join(",")).join(" "));
    travelled.setAttribute("fill", "none");
    travelled.setAttribute("stroke", "#245f73");
    travelled.setAttribute("stroke-width", "6");
    svg.appendChild(travelled);

    const [labelX, labelY] = project(lineProgress(state.transition.geometry.coordinates, 0.5).point);
    const label = document.createElementNS(namespace, "text");
    label.setAttribute("x", labelX);
    label.setAttribute("y", labelY - 7);
    label.setAttribute("text-anchor", "middle");
    label.setAttribute("paint-order", "stroke");
    label.setAttribute("stroke", "#fffefb");
    label.setAttribute("stroke-width", "4");
    label.setAttribute("fill", "#111111");
    label.setAttribute("font-size", "11");
    label.textContent = "Confirmed overnight flight";
    svg.appendChild(label);
  }
  if (state.kind === "leg") {
    const travelled = document.createElementNS(namespace, "polyline");
    const visualMode = transportVisualMode(state.leg);
    if (visualMode) travelled.classList.add(`trail-${visualMode}`, "trail-active");
    travelled.setAttribute("points", state.partial.map(project).map((point) => point.join(",")).join(" "));
    travelled.setAttribute("fill", "none");
    travelled.setAttribute("stroke", transportColor(visualMode) || "#245f73");
    travelled.setAttribute("stroke-width", visualMode ? "8" : "6");
    svg.appendChild(travelled);
  }
  if (state.kind === "unresolved_leg") {
    const endpointPoints = state.endpoints.map(project);
    const transfer = document.createElementNS(namespace, "polyline");
    transfer.setAttribute("points", endpointPoints.map((point) => point.join(",")).join(" "));
    transfer.setAttribute("fill", "none");
    transfer.setAttribute("stroke", "#245f73");
    transfer.setAttribute("stroke-width", "5");
    transfer.setAttribute("stroke-dasharray", "3 13");
    transfer.setAttribute("stroke-dashoffset", String(-state.fraction * 36));
    svg.appendChild(transfer);
    endpointPoints.forEach(([x, y], index) => {
      const endpoint = document.createElementNS(namespace, "circle");
      endpoint.setAttribute("cx", x); endpoint.setAttribute("cy", y); endpoint.setAttribute("r", "10");
      endpoint.setAttribute("fill", "none"); endpoint.setAttribute("stroke", "#245f73"); endpoint.setAttribute("stroke-width", "3");
      endpoint.setAttribute("opacity", String(index === 0 ? 1 - state.fraction * 0.7 : 0.3 + state.fraction * 0.7));
      svg.appendChild(endpoint);
    });
  }
  const visibleStops = day ? visibleLocations(day) : (state.kind === "transition" ? [
    { role: "activity", place: state.transition.from_place },
    { role: "activity", place: state.transition.to_place }
  ] : [{ role: "lodging_base", place: state.fromDay.stops.at(-1).place }]);
  visibleStops.forEach((stop) => {
    const [x, y] = project(coordinateForStop(stop));
    const uncertainBase = uncertainLodging(stop);
    const mealStop = mealMarkerStop(stop);
    if (uncertainBase) {
      const halo = document.createElementNS(namespace, "circle");
      halo.setAttribute("cx", x); halo.setAttribute("cy", y); halo.setAttribute("r", "15");
      halo.setAttribute("fill", "rgba(169, 107, 66, 0.14)"); halo.setAttribute("stroke", "#a96b42");
      halo.setAttribute("stroke-width", "2"); halo.setAttribute("stroke-dasharray", "5 4");
      svg.appendChild(halo);
    }
    const circle = document.createElementNS(namespace, "circle");
    circle.setAttribute("cx", x); circle.setAttribute("cy", y); circle.setAttribute("r", mealStop ? "11" : uncertainBase ? "3" : "5");
    circle.setAttribute("fill", mealStop && stop.option_role !== "alternative" ? "#246c50" : "#fffefb");
    circle.setAttribute("stroke", mealStop ? stop.option_role === "alternative" ? "#94600f" : "#fffefb" : "#c7442f");
    circle.setAttribute("stroke-width", mealStop ? "3" : "2");
    if (mealStop && stop.evidence_status === "provisional") circle.setAttribute("stroke-dasharray", "3 2");
    svg.appendChild(circle);

    if (mealStop) {
      const glyph = document.createElementNS(namespace, "text");
      glyph.setAttribute("class", "trail-meal-glyph");
      glyph.setAttribute("x", x); glyph.setAttribute("y", y + 4);
      glyph.textContent = String(stop.rank);
      svg.appendChild(glyph);
    }
    const label = document.createElementNS(namespace, "text");
    label.setAttribute("x", x + (mealStop ? 16 : 9)); label.setAttribute("y", y - (mealStop ? 12 : 9));
    label.setAttribute("paint-order", "stroke"); label.setAttribute("stroke", "#fffefb");
    label.setAttribute("stroke-width", "4"); label.setAttribute("fill", mealStop ? stop.option_role === "alternative" ? "#6d470b" : "#174b38" : "#111111");
    label.setAttribute("font-size", "11"); label.setAttribute("font-weight", mealStop ? "850" : "650");
    label.textContent = mealStop
      ? mealMarkerLabel(stop)
      : uncertainBase ? `${stop.place.name} hotel area · location TBD` : stop.place.name;
    svg.appendChild(label);
  });
  if (state.kind !== "unresolved_leg") {
    const [markerX, markerY] = project(day ? displayPoint(day, state) : state.point);
    const timerEvent = stationaryTimerEventAt(day, state, selectedMinute);
    const timer = timerEvent && eventDuration(timerEvent) ? eventProgress(timerEvent, selectedMinute) : null;
    if (timer) {
      const timerTrack = document.createElementNS(namespace, "circle");
      timerTrack.setAttribute("class", "trail-stop-timer-track");
      timerTrack.setAttribute("cx", markerX); timerTrack.setAttribute("cy", markerY); timerTrack.setAttribute("r", "16");
      svg.appendChild(timerTrack);
      const timerProgress = document.createElementNS(namespace, "circle");
      timerProgress.setAttribute("class", "trail-stop-timer-progress");
      timerProgress.setAttribute("cx", markerX); timerProgress.setAttribute("cy", markerY); timerProgress.setAttribute("r", "16");
      timerProgress.setAttribute("pathLength", "100"); timerProgress.setAttribute("stroke-dasharray", "100");
      timerProgress.setAttribute("stroke-dashoffset", String(100 * (1 - timer.remainingFraction)));
      svg.appendChild(timerProgress);
      const timerText = document.createElementNS(namespace, "text");
      timerText.setAttribute("class", "trail-stop-duration-label");
      timerText.setAttribute("x", markerX + 22); timerText.setAttribute("y", markerY + 20);
      timerText.textContent = timerLabel(timerEvent);
      svg.appendChild(timerText);
    }
    const current = document.createElementNS(namespace, "circle");
    const activeMeal = day ? activeMealLocationAt(day, state, selectedMinute) : null;
    const visualMode = state.kind === "leg" ? transportVisualMode(state.leg) : null;
    if (visualMode) current.classList.add(`trail-position--${visualMode}`);
    if (activeMeal) current.classList.add(`trail-position--${activeMeal.exact ? "meal" : "meal-area"}`);
    current.setAttribute("cx", markerX); current.setAttribute("cy", markerY); current.setAttribute("r", activeMeal ? "15" : emphasizedVisualMode(visualMode) ? "10" : "8");
    const schematic = markerVariant(state) === "schematic";
    current.setAttribute("fill", activeMeal ? "none" : schematic ? "#fffefb" : "#c7442f");
    current.setAttribute("stroke", activeMeal ? activeMeal.exact ? "#246c50" : "#94600f" : schematic ? "#245f73" : "#fffefb");
    current.setAttribute("stroke-width", activeMeal ? "3" : schematic ? "4" : "3");
    if (activeMeal && !activeMeal.exact) current.setAttribute("stroke-dasharray", "4 3");
    svg.appendChild(current);
  }
  elements.mapContainer.replaceChildren(svg);
}

elements.tripRange.addEventListener("input", () => {
  stopPlayback();
  resumeCurrentRowFollowing();
  const position = tripPositionForValue(Number(elements.tripRange.value));
  const previousSegment = activeTimelineIndex;
  activeTimelineIndex = position.segmentIndex;
  activeBoundaryFraction = position.fraction || 0;
  autoFollowing = true;
  elements.mapRecenter.hidden = true;
  if (position.kind === "day") {
    const dayChanged = position.dayIndex !== selectedDayIndex || previousSegment !== position.segmentIndex;
    selectedDayIndex = position.dayIndex;
    selectedMinute = position.minute;
    if (dayChanged) renderDay(false); else renderMinute(false);
  } else {
    renderBoundary(false);
  }
  followScrubCamera(previousSegment);
});

elements.tripRange.addEventListener("change", () => {
  const segment = timelineSegments[activeTimelineIndex];
  if (segment.kind === "day") {
    const state = renderMinute(false);
    fitCurrentState(state);
  } else {
    fitBoundary(currentJourneyContext(), true);
  }
});

elements.dayRange.addEventListener("input", () => {
  stopPlayback();
  resumeCurrentRowFollowing();
  const previousSegment = activeTimelineIndex;
  activeTimelineIndex = daySegmentIndexes.get(selectedDayIndex);
  activeBoundaryFraction = 0;
  autoFollowing = true;
  elements.mapRecenter.hidden = true;
  selectedMinute = Number(elements.dayRange.value);
  renderMinute(false);
  followScrubCamera(previousSegment);
});

elements.dayRange.addEventListener("change", () => {
  autoFollowing = true;
  elements.mapRecenter.hidden = true;
  renderMinute(true);
});

[elements.tripRange, elements.dayRange].forEach((range) => {
  range.addEventListener("pointerdown", beginTimelineScrub);
});
window.addEventListener("pointerup", endTimelineScrub);
window.addEventListener("pointercancel", endTimelineScrub);

elements.play.addEventListener("click", () => {
  if (playbackFrame) {
    stopPlayback();
  } else {
    resumeCurrentRowFollowing();
    startPlayback();
  }
});
elements.dayStopViewport.addEventListener("wheel", suspendCurrentRowFollowing, { passive: true });
elements.dayStopViewport.addEventListener("touchstart", suspendCurrentRowFollowing, { passive: true });
elements.dayStopViewport.addEventListener("pointerdown", suspendCurrentRowFollowing);
elements.dayStopViewport.addEventListener("scroll", () => {
  if (!followCurrentRow) window.requestAnimationFrame(updateCurrentRowControl);
}, { passive: true });
elements.dayStopViewport.addEventListener("keydown", (event) => {
  if (["ArrowUp", "ArrowDown", "PageUp", "PageDown", "Home", "End"].includes(event.key)) suspendCurrentRowFollowing();
});
elements.showCurrentRow.addEventListener("click", () => {
  elements.dayStopViewport.focus({ preventScroll: true });
  resumeCurrentRowFollowing();
});
document.addEventListener("keydown", (event) => {
  if (event.code !== "Space" || event.repeat || event.altKey || event.ctrlKey || event.metaKey) return;
  if (event.target instanceof Element && event.target.closest("input:not([type='range']), textarea, select, button, a[href], [contenteditable='true']")) return;
  event.preventDefault();
  playbackFrame ? stopPlayback() : startPlayback();
});
elements.showAlternatives.addEventListener("change", () => {
  const day = currentDay();
  setSourceData("journey-alternatives", alternativeFeatures(day));
  if (fallbackMode && !mapReady) renderSvgFallback();
});
elements.mapRecenter.addEventListener("click", recenterRoute);

renderTripSegments();
renderTripTicks();
renderDay(false);
initializeMap();
