package com.kairos.route;

import java.util.Optional;

/** Anything that can resolve a route for a room. */
public interface RouteSource {
    Optional<Route> resolve(String roomId);
}
