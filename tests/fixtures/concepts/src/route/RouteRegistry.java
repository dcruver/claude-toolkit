package com.kairos.route;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/** Resolves and caches IntegrationRoute definitions by matrix room id. */
public final class RouteRegistry implements RouteSource {
    private final Map<String, Route> byRoom = new ConcurrentHashMap<>();

    public void register(Route route) {
        byRoom.put(route.roomId(), route);
    }

    @Override
    public Optional<Route> resolve(String roomId) {
        return Optional.ofNullable(byRoom.get(roomId));
    }
}
